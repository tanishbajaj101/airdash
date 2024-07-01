import 'package:airdash/constants/constants.dart';
import 'package:appwrite/appwrite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dart_appwrite/dart_appwrite.dart' as appwrite;

final dartclientProvider = Provider<appwrite.Client>((ref) {
  return appwrite.Client()
      .setEndpoint(AppwriteConstants.endPoint)
      .setProject(AppwriteConstants.projectId)
      .setKey(
          'e6dd15311a6078919f93348d2ea8b542d2f136aaffd33232c6ce93ab85b7648bf88f2514adb60e3b58c6c29b2ae2fa9bd61a891d33dce52c74598d4a94e670b9f8c50c58d42132a3c0b3a512430fb20d0f3b2fecc991ba53abb50d808d0531297611bdb326087e84a179ce87e569fc721c7a2f6b7e6ccf550055d697d0019ead')
      .setSelfSigned(status: true);
});

final appwriteClientProvider = Provider((ref) {
  Client client = Client();
  return client
      .setEndpoint(AppwriteConstants.endPoint)
      .setProject(AppwriteConstants.projectId)
      .setSelfSigned(status: true);
});

final appwriteAccountProvider = Provider((ref) {
  final client = ref.watch(appwriteClientProvider);
  return Account(client);
});

final appwriteDatabaseProvider = Provider((ref) {
  final client = ref.watch(appwriteClientProvider);
  return Databases(client);
});

final appwriteStorageProvider = Provider((ref) {
  final client = ref.watch(appwriteClientProvider);
  return Storage(client);
});

final appwriteRealtimeProvider = Provider((ref) {
  final client = ref.watch(appwriteClientProvider);
  return Realtime(client);
});
