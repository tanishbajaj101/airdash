import 'package:flutter/foundation.dart';

class Config {
  static const String customPairingFunctionUrl =
      "https://us-central1-$firebaseProjectId.cloudfunctions.net/pairing";
  static const String firebaseApiKey =
      "AIzaSyBsORwaBkFp-GjmIyr2oV7M6BUzH5sAkiM";
  static const String firebaseProjectId = "airdash-4ac74";
  static const String mixpanelProjectToken = "33381a2c33381a2c33381a2c33381a2c";
  static const String sentryDsn =
      "https://216a0a5552cd2571cd658c34670b4177@o4507526597246976.ingest.de.sentry.io/4507526598950992";

  static const sendErrorAndAnalyticsLogs = !kDebugMode;

  static String getPairingFunctionUrl() {
    return 'https://us-central1-$firebaseProjectId.cloudfunctions.net/pairing';
  }
}
