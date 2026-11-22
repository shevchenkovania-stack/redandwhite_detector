import 'package:flutter/material.dart';

import 'src/app/home_page.dart';

void main() {
  // SharedPreferences и sqflite нужны до создания сессии.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LampDetectionApp());
}

class LampDetectionApp extends StatelessWidget {
  const LampDetectionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'lamp_detection demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blueGrey,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}
