import 'package:flutter/material.dart';

import 'home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LampSimApp());
}

class LampSimApp extends StatelessWidget {
  const LampSimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'lamp_detection тренажёр',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blueGrey,
        brightness: Brightness.dark,
      ),
      home: const SimHomePage(),
    );
  }
}
