import 'package:airdash/core/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:appwrite/appwrite.dart';

import '../model/user.dart';
import '../reporting/error_logger.dart';
import '../reporting/logger.dart';
import '../shared_preferences_store.dart';
import 'home.dart';

final loadingTextProvider = StateProvider<String>((ref) => '');
final showTryAgainProvider = StateProvider<bool>((ref) => false);

class SetupScreen extends StatefulWidget {
  const SetupScreen({Key? key}) : super(key: key);

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  var loadingText = '';
  var showTryAgain = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(builder: (context, ref, _) {
      final loadingTextState = ref.watch(loadingTextProvider);
      final showTryAgainState = ref.watch(showTryAgainProvider);

      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(loadingTextState),
              if (showTryAgainState)
                TextButton(
                  onPressed: () async {
                    ref.watch(loadingTextProvider.notifier).state =
                        'Setting up';
                    setState(() {
                      showTryAgain = false;
                      loadingText = 'Setting up';
                    });
                    await Future<void>.delayed(const Duration(seconds: 1));
                    await _trySignIn(ref);
                  },
                  child: const Text('Try Again'),
                ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _trySignIn(WidgetRef ref) async {
    var prefs = await SharedPreferences.getInstance();
    var userState = UserState(prefs);

    var storedUser = userState.getCurrentUser();
    if (storedUser != null) {
      await userState.saveUser(storedUser);
      _navigateToHome();
      logger('SETUP: Already signed in, showing home');
    } else {
      logger('SETUP: Starting anonymous user sign in');
      ref.watch(loadingTextProvider.notifier).state = 'Setting up';
      setState(() {
        loadingText = 'Setting up';
      });
      try {
        Account account = ref.watch(appwriteAccountProvider);
        final result = await account.createAnonymousSession();
        var user = User.create(result.userId);
        await userState.saveUser(user);

        _navigateToHome();
        logger('SETUP: Anonymous user signed in, showing home');
      } catch (error, stack) {
        ErrorLogger.logStackError('failedAnonSignIn', error, stack);
        ref.watch(showTryAgainProvider.notifier).state = true;
        setState(() {
          showTryAgain = true;
          loadingText = 'Setup failed. Check your internet connection.';
        });
      }
    }
  }

  void _navigateToHome() {
    var route = PageRouteBuilder<void>(
      pageBuilder: (context, animation1, animation2) => const HomeScreen(),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
    if (mounted) {
      Navigator.of(context).pushReplacement(route);
    }
  }
}
