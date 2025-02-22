import 'dart:async';
import 'dart:math';

import 'package:Masa_Chat/service/browser.dart';
import 'package:Masa_Chat/service/database_service.dart';
import 'package:Masa_Chat/widgets/group_tile.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'signaling.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

String getMimeType() {
  if (kIsWeb) {
    return if_safari();
  } else {
    // 他のブラウザのMIMEタイプ
    return 'video/webm; codecs="vp8, vorbis"';
  }
}

final mimeType = getMimeType();

class VideoCallPage extends StatefulWidget {
  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  static const _chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
  static final _rnd = Random();

  static String getRandomString(int length) => String.fromCharCodes(Iterable.generate(length, (index) => _chars.codeUnitAt(_rnd.nextInt(_chars.length))));

  final signaling = Signaling(localDisplayName: getRandomString(20));
  FirebaseFirestore db = FirebaseFirestore.instance;
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> remoteRenderers = {};
  final Map<String, bool?> remoteRenderersLoading = {};

  bool inCalling = true;
  String? roomId = classId;
  bool localRenderOk = false;
  bool _isRecording = false;
  String outputPath = "recording/recording_data.mp4";
  Function(dynamic blob, bool isLastOne)? onDataChunk;
  String mimeType = 'video/webm';
  late MediaStream stream;
  var _native;
  var _recorder;
  var _completer;
  var objectUrl = "";
  bool if_recording = true;
  MediaRecorder _mediaRecorder = MediaRecorder();
  late MediaStream _combinedStream;
  var text = "";
  bool isScreenSharing = false;
  bool mute = true;

  startRecording() async {
    stream = signaling.getLocalStream(outputPath);
    try {
      _mediaRecorder.startWeb(stream,mimeType: 'audio/webm' );
    }
    catch (err1) {
      // Fallback for iOS
      _mediaRecorder.startWeb(stream,mimeType: 'video/mp4' );
    }
    setState(() {
      if_recording = false;
    });
  }
  Future<MediaStream> _combineStreams(List<MediaStream> streams) async {
    // 新しい空のMediaStreamを作成
    var combinedStream = await createLocalMediaStream('combinedStream');
    for (var stream in streams) {
      print("streams.length=${streams.length}");
      for (var track in stream.getTracks()) {
        await combinedStream.addTrack(track);
      }
    }
    print("combinedStream=$combinedStream");
    return combinedStream;
  }

  stopRecording() async {
    objectUrl = await _mediaRecorder.stop();
    print(objectUrl);
    setState(() {
      if_recording = true;
      
    });
    await showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text(
              "授業録画ファイルの名前",
              textAlign: TextAlign.center,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min, 
              children: [
                TextField(
                  onChanged: (val) {
                    setState(() {
                      text = val;
                    });
                  },
                  controller: TextEditingController(text: DateFormat('yyyy年M月d日').format(DateTime.now())),
                  style: const TextStyle(color: Colors.black),
                  decoration: InputDecoration(
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                      color: Colors.green),
                        borderRadius: BorderRadius.circular(22)),
                      errorBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.red),
                        borderRadius: BorderRadius.circular(22)
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: Colors.green
                        ),
                        borderRadius: BorderRadius.circular(22)
                      )
                    ),
                  ),
                ]
              ),
              actions: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green
                      ),
                      child: const Text("キャンセル"),
                    ),
                    const SizedBox(width: 15,),
                    ElevatedButton(
                      onPressed: () async {
                        if (text != "") {
                          setState(() {
                            Navigator.of(context).pop();
                          });
                          uploadVideo(objectUrl);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                      child: const Text("保存"),
                    ),
                  ]
                )
              ],
          );
        }
      );
  }

  sendMessage(String fileUrl,String filePath) {
    Map<String, dynamic> chatMessagesMap = {
      "message": "録画ファイル",
      "sender": "bot",
      "time": DateTime.now().millisecondsSinceEpoch,
      "uid": "bot",
      "fileUrl": fileUrl, // 通常のメッセージ
      "fileName": "$text",
      "filePath": ""
    };
    
    DatabaseService().sendRecording(groupId, fileUrl,text);
  }

  Future<void> uploadVideo(String videoURL) async {
    try {
      final path = "videos/${DateTime.now().millisecondsSinceEpoch}/$text.mp4";
      final storageRef = FirebaseStorage.instanceFor(bucket: "gs://masa-chat-sechack.appspot.com").ref("/").child('$path');
      try {
        final data = await http.get(Uri.parse(videoURL));
        var metadata = SettableMetadata(
          contentType: "video/mp4",
        );
        print(data);
        final uploadTask = storageRef.putData(data.bodyBytes);
        await uploadTask.whenComplete(() async {
          sendMessage(await storageRef.getDownloadURL(),path);
          print(await storageRef.getDownloadURL());
          print('Upload complete');
        });
      } catch (e) {
        print("エラー $e");
      }
    } catch (e) {
      print('Error uploading video: $e');
    }
  }

  @override
  void initState() {
    super.initState();

    signaling.onAddLocalStream = (peerUuid, displayName, stream) {
      setState(() {
        localRenderer.srcObject = stream;
        localRenderOk = stream != null;
      });
    };

    signaling.onAddRemoteStream = (peerUuid, displayName, stream) async {
      final remoteRenderer = RTCVideoRenderer();
      await remoteRenderer.initialize();
      remoteRenderer.srcObject = stream;

      setState(() => remoteRenderers[peerUuid] = remoteRenderer);
      
    };

    signaling.onRemoveRemoteStream = (peerUuid, displayName) {
      if (remoteRenderers.containsKey(peerUuid)) {
        remoteRenderers[peerUuid]!.srcObject = null;
        remoteRenderers[peerUuid]!.dispose();

        setState(() {
          remoteRenderers.remove(peerUuid);
          remoteRenderersLoading.remove(peerUuid);
        });
      }
    };

    signaling.onConnectionConnected = (peerUuid, displayName) {
      setState(() => remoteRenderersLoading[peerUuid] = false);
    };

    signaling.onConnectionLoading = (peerUuid, displayName) {
      setState(() => remoteRenderersLoading[peerUuid] = true);
    };

    signaling.onConnectionError = (peerUuid, displayName) {
      print('Connection failed with $displayName');
    };

    signaling.onGenericError = (errorText) {
      print(errorText);
    };
    
    init();
    _connect();
  }

  Flex view({required List<Widget> children}) {
    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return isLandscape ? Row(children: children) : Column(children: children);
  }

  Future<void> init() async {    
    await localRenderer.initialize();
    await Permission.camera.request();
    await Permission.microphone.request();
  }

  void _connect() async {
    await signaling.reOpenUserMedia();
    await signaling.join(roomId!);
  }
  
  void disposeRemoteRenderers() {
    for (final remoteRenderer in remoteRenderers.values) {
      remoteRenderer.dispose();
    }

    remoteRenderers.clear();
  }

  @override
  deactivate() {
    super.deactivate();
    localRenderer.dispose();
    disposeRemoteRenderers();
  }
  Future<void> hangUp(bool exit) async {
    setState(() {

      if (exit) {
        roomId = '';
      }
    });

    await signaling.hangUp(exit);

    setState(() {
      disposeRemoteRenderers();
    });
  }

  screenSharing() async {
    if (isScreenSharing) {
      await signaling.stopScreenSharing();
      setState(() {
        isScreenSharing = false;
      });
    } else {
      await signaling.screenSharing();
      setState(() {
        isScreenSharing = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text("Masa Call"
        ),
        backgroundColor: Colors.green,
        actions: [
          IconButton(
            onPressed: () async {
              await hangUp(true);
              setState(() {
                roomId = "";
                inCalling = false;
              });
              Navigator.pop(context);
            }, 
            icon: Icon(Icons.call_end))
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: inCalling
          ? SizedBox(
              width: 300,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  FloatingActionButton(
                    onPressed: () async { 
                      if_recording
                        ? await startRecording()
                        : await stopRecording();
                    },
                    tooltip: 'recording',
                    child: Icon(
                      if_recording
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off
                      )
                  ),
                  FloatingActionButton(
                    onPressed: () async {
                      await screenSharing();
                    },
                    tooltip: 'Screen Sharing',
                    child: Icon(Icons.screen_share),
                  ),
                  FloatingActionButton(
                    onPressed: () async {
                      await signaling?.switchCamera;
                    },
                    tooltip: 'Switch Camera',
                    child: Icon(Icons.switch_camera),
                  ),
                  FloatingActionButton(
                    child: Icon(mute 
                      ? Icons.mic
                      : Icons.mic_off),
                    onPressed: () async {
                      mute = await signaling.muteMic();
                      setState(() {
                        mute = mute;
                      });
                    },
                    tooltip: 'Mute Mic',
                  )
                ],
              ),
            )
          : null,
      body: Container(
        child: Column(
          children: [
            Expanded(
              child: view(
                children: [
                  if (localRenderOk) ...[
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0XFF2493FB),
                          ),
                        ),
                        child: RTCVideoView(localRenderer),
                      ),
                    ),
                  ],
                  for (final remoteRenderer in remoteRenderers.entries) ...[
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0XFF2493FB),
                          ),
                        ),
                        child: false == remoteRenderersLoading[remoteRenderer.key]
                            ? RTCVideoView(remoteRenderer.value)
                            : const Center(
                                child: CircularProgressIndicator(),
                        )
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      )
    );
  }
}
