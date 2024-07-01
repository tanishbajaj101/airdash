import 'dart:async';

import 'package:airdash/constants/constants.dart';
import 'package:airdash/core/providers.dart';
import 'package:appwrite/appwrite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../helpers.dart';
import '../model/device.dart';
import '../reporting/error_logger.dart';
import '../reporting/logger.dart';

final signalingProvider = Provider<Signaling>((ref) {
  return Signaling(ref);
});

class Signaling {
  CallbackErrorState? callbackErrorState;
  MissingPingErrorState? missingPingErrorState;
  DateTime? lastSignalingMessageReceived;

  List<String> sentErrors = [];

  Timer? observerTimer;
  StreamSubscription<RealtimeMessage>? _messagesStream;

  var receivedMessages = <String, dynamic>{};

  late Databases databases;
  late Realtime realtime;
  Signaling(Ref ref) {
    databases = ref.watch(appwriteDatabaseProvider);
    realtime = ref.watch(appwriteRealtimeProvider);
  }

  Future<void> observe(Device localDevice,
      Function(String message, String senderId) onMessage) async {
    restartListen(localDevice, onMessage);
  }

  // this listens for some? messages
  void restartListen(Device localDevice, Function onMessage) {
    _messagesStream?.cancel();
    _messagesStream = realtime
        .subscribe([
          'databases.${AppwriteConstants.databaseId}.collections.${AppwriteConstants.messages}.documents'
        ])
        .stream
        .listen((RealtimeMessage response) async {
          lastSignalingMessageReceived = DateTime.now();
          var state = callbackErrorState;
          if (state != null) {
            ErrorLogger.logSimpleError(
                'observerCallbackErrorRecovery',
                <String, dynamic>{
                  'errorCount': state.callbackErrors.length,
                  'startedAt': state.startedAt.toIso8601String(),
                  'lastErrorAt': state.lastErrorAt.toIso8601String(),
                  'errors': state.callbackErrors.map((e) => e.toString()),
                },
                1);
            callbackErrorState = null;
          }
          if (missingPingErrorState != null) {
            ErrorLogger.logSimpleError(
                'observerMissingPingRecovery',
                <String, dynamic>{
                  'callbackErrorState': state != null,
                  'errors': missingPingErrorState!.restartCount,
                },
                1);
            missingPingErrorState = null;
          }

          try {
            await _handleDocs(response, onMessage);
          } catch (error, stack) {
            ErrorLogger.logStackError(
                'signaling_handlingDocsError', error, stack);
          }
        }, onError: (Object error, StackTrace stack) async {
          if (callbackErrorState == null) {
            callbackErrorState = CallbackErrorState();
            callbackErrorState!.callbackErrors.add(error);
            ErrorLogger.logStackError(
                'observerError_callbackError', error, stack, 1);
          } else {
            callbackErrorState!.lastErrorAt = DateTime.now();
            callbackErrorState!.callbackErrors.add(error);
            print('SIGNALING: Added new callback error to error state');
          }

          // Delay to not cause infinite quick restarts in case of
          // immediate error
          await Future<void>.delayed(const Duration(seconds: 5));
          restartListen(localDevice, onMessage);
          // Send ping to get message quickly in case connection is restored
          sendPing(this, localDevice);
        });
    logger('RECEIVER: Listening for files...');

    observerTimer?.cancel();
    observerTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      int? lastReceived = lastSignalingMessageReceived?.millisecondsSinceEpoch;
      var now = DateTime.now().millisecondsSinceEpoch;

      // We should get a ping every 60 seconds so if we have not in 100
      // seconds restart observer.
      if (lastReceived == null || now - lastReceived > 5 * 60 * 1000 + 10) {
        var callbackError = callbackErrorState;
        if (callbackError == null ||
            secondsSince(callbackError.lastErrorAt) > 10) {
          logger(
              'SIGNALING: No error or ping received recently, restarting observer...');
          if (missingPingErrorState == null) {
            ErrorLogger.logSimpleError('observerError_missingPing', null, 1);
            missingPingErrorState = MissingPingErrorState();
          }
          missingPingErrorState!.restartCount += 1;
          restartListen(localDevice, onMessage);
          // Send ping to get message quickly in case connection is restored
          sendPing(this, localDevice);
        }
      }
    });
  }

  // it was giving list of docs it only has one
  // CHANGE THIS FUNCTION manually
  Future<void> _handleDocs(RealtimeMessage message, Function onMessage) async {
    final String docId = message.payload['\$id'] as String;
    if (receivedMessages[docId] != null) {
      return;
    }
    receivedMessages[docId] = true;

    var data = message.payload;
    DateTime date = data['date'] as DateTime;
    var messageText = data['message'] as String;
    var senderId = data['senderId'] as String;

    if (date.millisecondsSinceEpoch <
        DateTime.now().millisecondsSinceEpoch - 15000) {
      var diff =
          DateTime.now().millisecondsSinceEpoch - date.millisecondsSinceEpoch;
      logger(
          'SIGNALING: Removing old message $messageText $senderId ${date.millisecondsSinceEpoch} $diff');
      await databases.deleteDocument(
        databaseId: AppwriteConstants.databaseId,
        collectionId: AppwriteConstants.messages,
        documentId: docId,
      );
      return;
    }

    onMessage(messageText, senderId);
    await databases.deleteDocument(
      databaseId: AppwriteConstants.databaseId,
      collectionId: AppwriteConstants.messages,
      documentId: docId,
    );
  }

  Future<String> sendMessage(
      String senderId, String receiverId, String message) async {
    final doc = await databases.createDocument(
      databaseId: AppwriteConstants.databaseId,
      collectionId: AppwriteConstants.messages,
      documentId: 'unique()',
      data: <String, dynamic>{
        'date': DateTime.now().toIso8601String(),
        'senderId': senderId,
        'receiverId': receiverId,
        'message': message,
        // Versioning is moved to connector.dart, but keep this for a while
        'version': 3,
      },
    );
    return doc.$id;
  }
}

class CallbackErrorState {
  DateTime startedAt = DateTime.now();
  DateTime lastErrorAt = DateTime.now();
  List<Object> callbackErrors = [];
}

class MissingPingErrorState {
  DateTime startedAt = DateTime.now();
  int restartCount = 1;
}
