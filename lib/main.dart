import 'package:flutter/material.dart';

// change initial screen as well
import 'interface/setup_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    var primaryColor = const Color.fromRGBO(150, 150, 250, 1);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: primaryColor),
          useMaterial3: true),
      home: const SetupScreen(),
    );
  }
}
