import 'dart:io';

import 'package:flutter/material.dart';

import 'home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Полностью автоматический прогон без нажатий: переменные окружения.
  //   LAMP_SIM_AUTO=1        старт мигания сам, через LAMP_SIM_DELAY_MS
  //   LAMP_SIM_DELAY_MS=8000 задержка до старта (успеть откалиброваться)
  //   LAMP_SIM_SPEED=slow|medium|fast
  //   LAMP_SIM_RANDOM=1      случайный режим
  //   LAMP_SIM_CLEAN=1       сразу режим «только кадр» на весь экран
  //   LAMP_SIM_OPENCV=1      после загрузки картинок сам прогнать сравнение
  //                          двух способов измерения (OpenCV только теневой
  //                          измеритель, решения он не видит)
  //   LAMP_SIM_OPENCV_OUT=path файл, куда положить текст сравнения; по
  //                          умолчанию lamp_opencv_compare.txt во временной
  //                          папке — у окна нет гарантированной консоли, а
  //                          числа сравнения должны быть читаемы после прогона
  final Map<String, String> env = Platform.environment;
  bool on(String key) {
    final String v = (env[key] ?? '').toLowerCase();
    return v == '1' || v == 'true';
  }

  runApp(
    LampSimApp(
      autoStart: on('LAMP_SIM_AUTO'),
      autoRandom: on('LAMP_SIM_RANDOM'),
      autoSpeed: env['LAMP_SIM_SPEED'],
      autoStartDelayMs: int.tryParse(env['LAMP_SIM_DELAY_MS'] ?? '') ?? 5000,
      startClean: on('LAMP_SIM_CLEAN'),
      autoOpenCv: on('LAMP_SIM_OPENCV'),
      openCvReportPath: env['LAMP_SIM_OPENCV_OUT'],
    ),
  );
}

class LampSimApp extends StatelessWidget {
  const LampSimApp({
    super.key,
    this.autoStart = false,
    this.autoRandom = false,
    this.autoSpeed,
    this.autoStartDelayMs = 5000,
    this.startClean = false,
    this.autoOpenCv = false,
    this.openCvReportPath,
  });

  final bool autoStart;
  final bool autoRandom;
  final String? autoSpeed;
  final int autoStartDelayMs;
  final bool startClean;
  final bool autoOpenCv;
  final String? openCvReportPath;

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
      home: SimHomePage(
        autoStart: autoStart,
        autoRandom: autoRandom,
        autoSpeed: autoSpeed,
        autoStartDelayMs: autoStartDelayMs,
        startClean: startClean,
        autoOpenCv: autoOpenCv,
        openCvReportPath: openCvReportPath,
      ),
    );
  }
}
