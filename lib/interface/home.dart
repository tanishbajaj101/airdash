import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airdash/constants/constants.dart';
import 'package:airdash/core/providers.dart';
import 'package:appwrite/appwrite.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../file_manager.dart';
import '../helpers.dart';
import '../intent_receiver.dart';
import '../interface/pairing_dialog.dart';
import '../model/device.dart';
import '../model/payload.dart';
import '../model/user.dart';
import '../model/value_store.dart';
import '../reporting/error_logger.dart';
import '../reporting/logger.dart';
import '../transfer/connector.dart';
import '../transfer/signaling.dart';
import './window_manager.dart';
import 'file_location_dialog.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends ConsumerState<HomeScreen>
    with TrayListener, WindowListener {
  Connector? connector;
  final IntentReceiver intentReceiver = IntentReceiver();

  final fileManager = FileManager();

  late final Databases databases;
  late final Signaling signaling;
  late final ValueStore valueStore;

  Device? currentDevice;
  bool isAutoStartEnabled = false;

  List<Device> devices = [];

  List<File> receivedFiles = [];
  Payload? selectedPayload;
  String? sendingStatus;
  String? receivingStatus;

  var isPickingFile = false;

  static const communicatorChannel =
      MethodChannel('io.flown.airdash/communicator');

  @override
  void initState() {
    windowManager.addListener(this);
    trayManager.addListener(this);
    super.initState();
    databases = ref.watch(appwriteDatabaseProvider);
    signaling = ref.watch(signalingProvider);
    init();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    intentReceiver.intentDataStreamSubscription?.cancel();
    intentReceiver.intentDataStreamSubscription = null;
    intentReceiver.intentTextStreamSubscription?.cancel();
    intentReceiver.intentTextStreamSubscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) async {
        logger('DROP: Files dropped ${detail.files.length}');
        var payload =
            FilePayload(detail.files.map((it) => File(it.path)).toList());
        await setPayload(payload, 'dropped');
      },
      onDragEntered: (detail) {
        showDropOverlay();
      },
      onDragExited: (detail) {
        Navigator.pop(context);
      },
      child: Scaffold(
        appBar: null,
        body: Column(
          children: [
            if (currentDevice != null) buildOwnDeviceView(currentDevice!),
            Expanded(
              child: SingleChildScrollView(
                child: SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (receivingStatus != null)
                        buildReceivingStatusBox(receivingStatus!),
                      if (receivedFiles.isNotEmpty)
                        buildRecentlyReceivedFilesCard(receivedFiles),
                      buildSelectFileArea(),
                      buildReceiverButtons(devices),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ButtonTheme(
                            height: 60,
                            minWidth: 200,
                            child: renderSendButton(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> init() async {
    try {
      await start().timeout(const Duration(seconds: 10));
    } catch (error, stack) {
      ErrorLogger.logStackError('startError', error, stack);
      showSnackBar('Could not connect. Check your internet connection.');
    }
  }

  Future<void> start() async {
    var prefs = await SharedPreferences.getInstance();
    await updateAutoStartStatus();

    valueStore = ValueStore(prefs);

    if (isMobile()) {
      observeIntentFile();
    }

    var deviceId = await valueStore.getDeviceId();
    var deviceName = await valueStore.getDeviceName();

    var user = UserState(prefs).getCurrentUser();
    var localDevice =
        Device(deviceId, deviceName, Platform.operatingSystem, user?.id);
    setState(() {
      currentDevice = localDevice;
    });

    connector = Connector(localDevice, signaling);
    devices = valueStore.getReceivers();

    ref
        .read(selectedDeviceProvider.notifier)
        .setDevice(valueStore.getSelectedDevice());

    await connector!.observe((payload, error, statusUpdate) async {
      if (payload == null) {
        if (error != null) {
          if (error is AppException) {
            showSnackBar(error.userError);
          } else {
            showSnackBar('Could not receive file. Try again.');
          }
          setState(() {
            receivingStatus = null;
          });
        } else {
          setState(() {
            receivingStatus = statusUpdate;
          });
        }
      } else if (payload is UrlPayload) {
        await launchUrl(payload.httpUrl, mode: LaunchMode.externalApplication);
        showSnackBar('URL opened');
        setState(() {
          receivingStatus = null;
        });
      } else if (payload is FilePayload) {
        var tmpFile = payload.files.first;
        try {
          // Only files created by app can be opened on macos without getting
          // permission errors or permission dialog.
          tmpFile = await fileManager.safeCopyToFileLocation(tmpFile);
        } catch (error, stack) {
          ErrorLogger.logStackError('downloadsCopyError', error, stack);
        }
        setState(() {
          receivedFiles = [...receivedFiles, tmpFile];
          receivingStatus = null;
        });
        addUsedFile([tmpFile]);
        showSnackBar('File received');
      } else {
        ErrorLogger.logSimpleError('invalidPayloadType');
      }
    });

    connector!.startPing();

    var transferActive = receivingStatus != null;
    fileManager.cleanUsedFiles(selectedPayload, receivedFiles, transferActive);

    try {
      await updateConnectionConfig();
    } catch (error, stack) {
      ErrorLogger.logStackError('infoUpdateError', error, stack);
    }
    //selectPasteboard();

    //startBluetooth();
  }
/*
  BeaconBroadcast beaconBroadcast = BeaconBroadcast();
  startBluetooth() {
    beaconBroadcast
        .setUUID('39ED98FF-2900-441A-802F-9C398FC199D2')
        .setMajorId(1)
        .setMinorId(100)
        .start();
  }
*/

  Future<void> updateAutoStartStatus() async {
    if (Platform.isMacOS) {
      try {
        isAutoStartEnabled = await communicatorChannel
                .invokeMethod<bool>("getAutoStartStatus") ??
            false;
      } catch (error) {
        print('Failed registering for auto start');
        print(error);
      }
    }
  }

  void showTransferFailedToast(String message) {
    var bar = SnackBar(
      duration: const Duration(seconds: 10),
      content: Text(message),
      action: SnackBarAction(
        textColor: Colors.white,
        label: 'Report Issue',
        onPressed: () async {
          var url =
              Uri.parse('https://github.com/simonbengtsson/airdash/issues');
          await launchUrl(url);
        },
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(bar);
  }

  Future<void> updateConnectionConfig() async {
    final doc = await databases.getDocument(
      databaseId: AppwriteConstants.databaseId,
      collectionId: 'appInfo',
      documentId: 'appInfo',
    );
    // convert this into a map
    var json = jsonEncode(doc.data);
    var prefs = await SharedPreferences.getInstance();
    prefs.setString('appInfo', json);
    logger('Updated cached appInfo');
  }

  @override
  void onWindowFocus() {
    //selectPasteboard();
    print('Window was focused...');
  }

  @override
  void onWindowEvent(String eventName) {}

  @override
  void onWindowBlur() {
    if (!isPickingFile && valueStore.isTrayModeEnabled()) {
      //windowManager.close();
    }
  }

  @override
  void onWindowClose() {
    if (!valueStore.isTrayModeEnabled()) {
      exit(1);
    }
  }

  @override
  void onTrayIconMouseDown() async {
    if (await windowManager.isVisible()) {
      await windowManager.close();
    } else {
      await windowManager.show();
    }
    print('tray icon mouse down');
  }

  @override
  void onTrayIconRightMouseDown() async {
    print('tray icon right mouse down');
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {
    print('tray icon right mouse up');
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    logger('TRAY: Menu item clicked ${menuItem.key}');
    if (menuItem.key == 'show_window') {
      logger('TRAY: Should focus/open window');
      await windowManager.show();
    } else if (menuItem.key == 'exit_app') {
      exit(1);
    }
  }

  Future<void> observeIntentFile() async {
    intentReceiver.observe((payload, error) async {
      if (payload == null) {
        showToast(error ?? 'Could not handle payload');
        return;
      }
      if (payload is FilePayload) {
        logger('HOME: Payload intent ${payload.files.length}');
      } else if (payload is UrlPayload) {
        print('HOME: Url intent, ${payload.httpUrl.toString()}');
      }
      await setPayload(payload, 'intent');
    });
  }

  void showSnackBar(String message) {
    if (mounted) {
      var bar = SnackBar(content: Text(message));
      ScaffoldMessenger.of(context).showSnackBar(bar);
    }
  }

  // Don't auto use pasteboard anymore since
  // ios present annoying permission dialog
  void selectPasteboard() async {
    try {
      final filePaths = await Pasteboard.files();
      final text = await Pasteboard.text ?? '';
      var isUrl = Uri.tryParse(text)?.hasAbsolutePath ?? false;
      if (filePaths.isNotEmpty) {
        var files = filePaths.map((it) => File(it)).toList();
        setState(() {
          selectedPayload = FilePayload(files);
        });
        print('Selected pasteboard files $filePaths');
      } else if (isUrl) {
        var url = Uri.parse(text);
        setState(() {
          selectedPayload = UrlPayload(url);
        });
        print('Selected url payload ${url.path}');
      }
    } catch (error, stack) {
      // Plugin currently not supported on android
      if (!Platform.isAndroid) {
        ErrorLogger.logStackError('couldNotSelectPasteboard', error, stack);
      }
    }
  }

  Future<void> sendPayload(Device receiver, Payload payload) async {
    if (payload is FilePayload) {
      for (var file in payload.files) {
        if (!(await file.exists())) {
          showToast('File not found. Try again.');
          setState(() {
            selectedPayload = null;
          });
          return;
        }
      }
    }
    setState(() {
      sendingStatus = 'Connecting...';
    });
    try {
      var fractionDigits = 0;
      if (payload is FilePayload) {
        fractionDigits = await getFractionDigits(payload.files.first);
      }
      String? lastProgressStr;
      int lastDone = 0;
      var lastTime = DateTime.now();
      await connector!.sendPayload(receiver, payload,
          (done, total, fileIndex, totalFiles) {
        var progress = done / total;
        var progressStr = (progress * 100).toStringAsFixed(fractionDigits);
        var speedStr = '';
        if (lastProgressStr != progressStr) {
          var diff = DateTime.now().difference(lastTime);
          var diffBytes = done - lastDone;
          speedStr = ' (${formatDataSpeed(diffBytes, diff)})';
          var fileIndexStr =
              totalFiles > 1 ? ' ${fileIndex + 1}/$totalFiles' : '';
          setState(() {
            sendingStatus = 'Sending $progressStr%$fileIndexStr$speedStr';
          });
          lastDone = done;
          lastTime = DateTime.now();
          lastProgressStr = progressStr;
        }
      });
      showSnackBar('File sent');
      setState(() {
        sendingStatus = null;
        selectedPayload = null;
      });
    } catch (error, stack) {
      logger('SENDER: Send file error "$error"');
      if (error is AppException) {
        if (error.type == 'firstDataMessageTimeout') {
          showTransferFailedToast(error.userError);
        } else {
          showSnackBar(error.userError);
        }
        ErrorLogger.logStackError(error.type, error, stack);
      } else if (error is grpc.GrpcError && error.code == 14) {
        showSnackBar("Sending failed. Try again.");
        ErrorLogger.logStackError('internetSenderError', error, stack);
      } else {
        showSnackBar("Sending failed. Try again.");
        ErrorLogger.logStackError('unknownSenderError', error, stack);
      }
      setState(() {
        sendingStatus = null;
      });
    }
  }

  Future<int> getFractionDigits(File file) async {
    var payloadSize = await file.length();
    var payloadMbSize = payloadSize / 1000000;
    return payloadMbSize > 1000 ? 1 : 0;
  }

  Future<void> openPairingDialog(Device device, BuildContext context) async {
    return showDialog(
        context: context,
        builder: (context) {
          return PairingDialog(
              localDevice: device,
              onPair: (receiver) async {
                setState(() {
                  devices.removeWhere((it) => it.id == receiver.id);
                  devices.add(receiver);
                  ref.read(selectedDeviceProvider.notifier).setDevice(receiver);
                });

                await valueStore.persistState(
                    connector, currentDevice!, devices, ref);
              });
        });
  }

  Widget renderSendButton() {
    Device? selectedDevice = ref.watch(selectedDeviceProvider);
    var disabled = selectedPayload == null ||
        selectedDevice == null ||
        sendingStatus != null;
    return OutlinedButton(
      onPressed: disabled
          ? null
          : () {
              sendPayload(selectedDevice, selectedPayload!);
            },
      child: Text(
        sendingStatus ?? "Send",
      ),
    );
  }

  Widget buildLog(List<Log> logs) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: logs.map((log) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 90,
              child: Text(log.time.toString().substring(10, 23),
                  style: const TextStyle(fontSize: 12)),
            ),
            SelectableText(log.message,
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'Courier',
                    color: Color(0xff555555))),
          ]);
        }).toList(),
      ),
    );
  }

  void openPhotoAndFileBottomSheet() {
    showModalBottomSheet<void>(
        context: context,
        builder: (context) {
          return SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.photo),
                  title: const Text('Media'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    openFilePicker(FileType.media);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.description),
                  title: const Text('Files'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    openFilePicker(FileType.any);
                  },
                ),
              ],
            ),
          );
        });
  }

  Future<void> openFilePicker(FileType type) async {
    isPickingFile = true;
    var result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Pick File',
      type: type,
      lockParentWindow: true,
      withData: false,
      allowCompression: false,
      withReadStream: true,
      allowMultiple: true,
    );
    if (result != null && result.files.isNotEmpty) {
      var files = result.files.map((it) => File(it.path!)).toList();
      var param = type == FileType.media ? 'media' : 'fileManager';
      await setPayload(FilePayload(files), param);
      logger('HOME: File selected ${files.length}');
    }
    isPickingFile = false;
    if (isDesktop()) {
      await windowManager.show();
    }
  }

  Future<void> setPayload(Payload payload, String source) async {
    if (payload is FilePayload) {
      for (var file in payload.files) {
        try {
          var length = await file.length();
          if (length <= 0) {
            throw Exception('Invalid file length $length');
          }
          addUsedFile([file]);
        } catch (error, stack) {
          ErrorLogger.logStackError('payloadSelectError', error, stack);
          showToast('Could not read selected file');
          return;
        }
      }
    }

    setState(() {
      selectedPayload = payload;
    });
  }

  Future<void> openFile(List<File> files) async {
    try {
      if (Platform.isIOS) {
        // Encode path to support filenames with spaces
        var paths = files.map((it) => Uri.encodeFull(it.path)).toList();
        logger('MAIN: Will open: ${paths.first}');
        await communicatorChannel
            .invokeMethod<void>('openFile', {'urls': paths});
      } else if (Platform.isAndroid) {
        if (files.length == 1) {
          var firstFile = files.first;
          var launchUrl = firstFile.path;
          logger('MAIN: Will open: $launchUrl');
          try {
            await communicatorChannel
                .invokeMethod<void>('openFile', {'url': launchUrl});
          } catch (error, stack) {
            ErrorLogger.logStackError(
                'noInstalledAppCouldOpenFile', error, stack);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text("No installed app could open this file")));
            }
          }
        } else {
          // Seems there is no way to preview multiple files on android
          // so openeing share sheet instead to let user decide what they
          // want to do.
          await openShareSheet(files, context);
        }
      } else {
        if (Platform.isLinux) {
          showToast(
              "Could not open file. See received files in your Downloads folder");
        }
        if (files.length > 1) {
          var firstFile = files.first;
          await fileManager.openFolder(firstFile.path);
        } else {
          // Spaces not supported on macos but works when encoded
          var firstFile = files.first;
          var encodedPath = Uri.encodeFull(firstFile.path);
          var url = Uri.parse('file:$encodedPath');
          logger('MAIN: Will open: ${url.path}');
          try {
            if (!await launchUrl(url)) {
              throw Exception('launchUrlErrorFalse');
            }
          } catch (error, stack) {
            ErrorLogger.logError(
                LogError('launchFileUrlError', error, stack, <String, String>{
              'encodedPath': encodedPath,
              'rawPath': firstFile.path,
            }));
            await fileManager.openFolder(firstFile.path);
          }
        }
      }
    } catch (error, stack) {
      ErrorLogger.logError(SevereLogError(
          'openFileAndFolderError', error, stack, <String, dynamic>{
        'path': files.tryGet(0)?.path ?? 'none',
        'count': files.length,
      }));
      showToast('Could not open file');
    }
  }

  void showToast(String message) {
    var bar = SnackBar(
      content: Text(message),
    );
    ScaffoldMessenger.of(context).showSnackBar(bar);
  }

  Widget buildRecentlyReceivedFilesCard(List<File> files) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8, left: 16, right: 16),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          //color: Colors.grey[100],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8.0, bottom: 0, right: 8),
              child: Row(
                children: [
                  buildSectionTitle('Received File'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      var transferActive = receivingStatus != null;
                      setState(() {
                        receivedFiles = [];
                        receivingStatus = null;
                      });
                      fileManager.cleanUsedFiles(
                          selectedPayload, receivedFiles, transferActive);
                      if (Platform.isMacOS) {
                        await communicatorChannel
                            .invokeMethod<void>('endFileLocationAccess');
                      }
                    },
                  ),
                ],
              ),
            ),
            ListTile(
              onTap: () {
                openFile(files);
              },
              trailing: IconButton(
                onPressed: () async {
                  if (isDesktop()) {
                    await fileManager.openFolder(files.first.path);
                    if (Platform.isLinux) {
                      showToast(
                          "Could not open file. See received files in your Downloads folder");
                    }
                  } else {
                    await openShareSheet(files, context);
                  }
                },
                icon: Icon(isDesktop()
                    ? Icons.folder_open
                    : (Platform.isIOS ? Icons.ios_share : Icons.share)),
              ),
              leading: Image.file(files.first, height: 40, fit: BoxFit.contain,
                  errorBuilder: (ctx, err, stack) {
                return const Icon(Icons.file_copy_outlined);
              }),
              title: files.length > 1
                  ? Text('${files.length} Received')
                  : Text(getFilename(files.first)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void selectFile() {
    if (Platform.isIOS) {
      openPhotoAndFileBottomSheet();
    } else {
      openFilePicker(FileType.any);
    }
  }

  Map<String, bool> disabledKeys = {};

  Widget buildSelectFileButton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, bottom: 8, top: 8),
          child: Row(
            children: [
              TextButton(
                  onPressed: disabledKeys['selectFileButton'] != null
                      ? null
                      : () async {
                          setState(
                              () => disabledKeys['selectFileButton'] = true);
                          selectFile();
                          await Future<void>.delayed(
                              Duration(milliseconds: isDesktop() ? 2000 : 500));
                          setState(
                              () => disabledKeys.remove('selectFileButton'));
                        },
                  child: const Row(
                    children: [
                      Icon(Icons.add),
                      SizedBox(width: 10),
                      Text('Select File',
                          style: TextStyle(overflow: TextOverflow.ellipsis)),
                    ],
                  )),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildSelectFileArea() {
    var payload = selectedPayload;
    Widget content = buildSelectFileButton();
    if (payload == null || payload is FilePayload && payload.files.isEmpty) {
      content = buildSelectFileButton();
    } else if (payload is UrlPayload) {
      content = buildSelectedUrlTile(payload.httpUrl);
    } else if (payload is FilePayload) {
      if (payload.files.length == 1) {
        content = buildSelectedFileTile(payload.files);
      } else {
        content = buildMultipleSelectedFilesTile(payload);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: buildSectionTitle('File to send'),
        ),
        content,
      ],
    );
  }

  Widget buildSelectedUrlTile(Uri url) {
    var urlString = url.toString();
    if (urlString.length > 100) {
      urlString = '${urlString.substring(0, 97)}...';
    }
    return ListTile(
      leading: const Icon(Icons.link),
      title: Text(urlString),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () {
          setState(() {
            selectedPayload = null;
          });
        },
      ),
    );
  }

  Widget buildMultipleSelectedFilesTile(FilePayload payload) {
    return ListTile(
      leading: const Icon(Icons.file_copy_outlined),
      title: Text('${payload.files.length} Selected'),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () {
          setState(() {
            selectedPayload = null;
          });
        },
      ),
    );
  }

  Widget buildSelectedFileTile(List<File> files) {
    var file = files.first;
    return ListTile(
      leading: Image.file(file, height: 40, fit: BoxFit.contain,
          errorBuilder: (ctx, err, stack) {
        return const Icon(Icons.file_copy_outlined);
      }),
      title: Text(getFilename(file)),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () {
          setState(() {
            selectedPayload = null;
          });
        },
      ),
    );
  }

  Future<void> openShareSheet(List<File> files, BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null) {
      await Share.shareXFiles(
        files.map((it) => XFile(it.path)).toList(),
        sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
      );
    }
  }

  void showDropOverlay() {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.white.withOpacity(0.95),
      barrierDismissible: false,
      barrierLabel: 'Dialog',
      transitionDuration: const Duration(milliseconds: 0),
      pageBuilder: (_, __, ___) {
        return const Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: Text('Drop File Here',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: Colors.grey)),
          ),
        );
      },
    );
  }

  Future<void> deleteDevice(Device device) async {
    setState(() {
      devices = devices.where((r) => r.id != device.id).toList();
      ref.read(selectedDeviceProvider.notifier).setDevice(devices.firstOrNull);
    });
    await valueStore.persistState(connector, currentDevice!, devices, ref);
  }

  Widget buildSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16),
      child: Text(text.toUpperCase(),
          style: const TextStyle(color: Colors.black54, fontSize: 13)),
    );
  }

  Widget buildReceiverButtons(List<Device> devices) {
    Device? selectedDevice = ref.watch(selectedDeviceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 8),
          child: buildSectionTitle('Select Receiver'),
        ),
        ...devices.map((it) {
          var selected = selectedDevice?.id == it.id;
          return ListTile(
            onLongPress: () {
              showDialog<void>(
                  context: context,
                  builder: (ctx) {
                    return AlertDialog(
                      title: const Text('Remove Device'),
                      content: const Text('Do you want to remove this device?'),
                      actions: [
                        TextButton(
                            onPressed: () async {
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('Cancel')),
                        TextButton(
                            onPressed: () async {
                              Navigator.of(ctx).pop();
                              deleteDevice(it);
                            },
                            child: const Text('Remove')),
                      ],
                    );
                  });
            },
            onTap: () async {
              ref.read(selectedDeviceProvider.notifier).setDevice(it);

              await valueStore.persistState(
                  connector, currentDevice!, devices, ref);
            },
            selected: selected,
            trailing: selected ? const Icon(Icons.check) : null,
            selectedTileColor: Colors.grey[100],
            leading: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(it.icon),
              ],
            ),
            title: Text(it.name),
            subtitle: Text(it.displayId),
          );
        }),
        Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 8),
          child: Row(
            children: [
              TextButton(
                  onPressed: currentDevice == null ||
                          disabledKeys['pairNewDevice'] != null
                      ? null
                      : () async {
                          setState(() => disabledKeys['pairNewDevice'] = true);
                          openPairingDialog(currentDevice!, context);
                          await Future<void>.delayed(
                              const Duration(milliseconds: 200));
                          setState(() => disabledKeys.remove('pairNewDevice'));
                        },
                  child: const Row(
                    children: [
                      Icon(Icons.add),
                      SizedBox(width: 10),
                      Text('Pair New Device',
                          style: TextStyle(overflow: TextOverflow.ellipsis)),
                    ],
                  )),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildOwnDeviceView(Device device) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            offset: Offset(0, 0),
            blurRadius: 10.0,
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16.0, top: 16),
              child: Text('THIS DEVICE ${kDebugMode ? ' (DEV)' : ''}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            ListTile(
              leading: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(device.icon),
                ],
              ),
              title: Text('${device.name}${kDebugMode ? '' : ''}'),
              subtitle: Text(device.displayId),
              trailing: PopupMenuButton<String>(
                onSelected: (String item) async {
                  if (item == 'licenses') {
                    PackageInfo packageInfo = await PackageInfo.fromPlatform();
                    var version = packageInfo.version;
                    if (mounted) {
                      showLicensePage(
                        context: context,
                        applicationName: 'AirDash',
                        applicationVersion: 'v$version',
                      );
                    }
                  } else if (item == 'changeDeviceName') {
                    openChangeDeviceNameDialog(currentDevice!);
                  } else if (item == 'openDownloads') {
                    try {
                      var prefs = await SharedPreferences.getInstance();
                      var valueStore = ValueStore(prefs);
                      var downloadsDir = await valueStore.getFileLocation();
                      await fileManager.openFolder(downloadsDir!.path);
                      if (Platform.isMacOS) {
                        await communicatorChannel
                            .invokeMethod<void>('endFileLocationAccess');
                      }
                    } catch (error, stack) {
                      ErrorLogger.logStackError(
                          'couldNotOpenDownloads', error, stack);
                    }
                    if (Platform.isLinux) {
                      showToast(
                          "Could not open file. See received files in your Downloads folder");
                    }
                  } else if (item == 'changeFileLocation') {
                    openFileLocationDialog(context, valueStore);
                  } else if (item == 'toggleTrayMode') {
                    await valueStore.toggleTrayModeEnabled();
                    await AppWindowManager().setupWindow();
                  } else if (item == 'toggleAutoStart') {
                    try {
                      await communicatorChannel
                          .invokeMethod<bool>('toggleAutoStart');
                      await updateAutoStartStatus();
                      setState(() {});
                      print("Toggled auto start status");
                    } catch (error, stack) {
                      print('Could not toggle auto start');
                      var details =
                          FlutterErrorDetails(exception: error, stack: stack);
                      FlutterError.presentError(details);
                    }
                  } else {
                    print('Invalid item selected');
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  if (isDesktop())
                    const PopupMenuItem<String>(
                      value: 'openDownloads',
                      child: Text('Received Files'),
                    ),
                  if (isDesktop())
                    const PopupMenuItem<String>(
                      value: 'changeFileLocation',
                      child: Text('Change File Location'),
                    ),
                  const PopupMenuItem<String>(
                    value: 'changeDeviceName',
                    child: Text('Change Device Name'),
                  ),
                  if (Platform.isMacOS)
                    const PopupMenuItem<String>(
                      value: 'toggleTrayMode',
                      child: Text('Toggle Tray Mode'),
                    ),
                  if (Platform.isMacOS)
                    PopupMenuItem<String>(
                      value: 'toggleAutoStart',
                      child: Text(
                          '${isAutoStartEnabled ? 'Disable' : 'Enable'} Auto Start'),
                    ),
                  const PopupMenuItem<String>(
                    value: 'licenses',
                    child: Text('Licenses'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void openChangeDeviceNameDialog(Device currentDevice) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
          content: TextFormField(
            decoration: const InputDecoration(
              suffixIcon: Icon(Icons.add),
              label: Text('This Device Name'),
            ),
            initialValue: currentDevice.name,
            onChanged: (text) async {
              var newDevice = currentDevice.withName(text);
              setState(() {
                this.currentDevice = newDevice;
              });
              await valueStore.persistState(connector, newDevice, devices, ref);
            },
          ),
          actions: [
            TextButton(
              child: const Text('Done'),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
          ]),
    );
  }

  Widget buildReceivingStatusBox(String statusMessage) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8, left: 16, right: 16),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: const BorderRadius.all(Radius.circular(10)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(statusMessage),
        ),
      ),
    );
  }
}
