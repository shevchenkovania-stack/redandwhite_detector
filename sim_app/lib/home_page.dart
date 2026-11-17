import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'sim_frame_source.dart';

/// Тестовая панель: мигание трёх картинок и эталонный счётчик вспышек.
/// Никакой детекции здесь нет — она делается на настоящем детекторе (камера).
/// Здесь только «правильный ответ»: сколько раз мигнула каждая лампа.
class SimHomePage extends StatefulWidget {
  const SimHomePage({super.key});

  @override
  State<SimHomePage> createState() => _SimHomePageState();
}

class _SimHomePageState extends State<SimHomePage> {
  final SimFrameSource _source = SimFrameSource();
  String _message = 'загрузка картинок…';

  bool _scanning = false;
  int _cycleStep = 0;
  Timer? _cycleTimer;

  // Эталон: сколько раз каждая лампа реально мигнула.
  int _flashWhite = 0;
  int _flashRed = 0;

  // Скорость перелистывания.
  _Speed _speed = _Speed.medium;

  // Режим: false — фиксированный цикл, true — случайная лампа и рваные паузы.
  bool _random = false;
  final Random _rng = Random();

  // Порядок сцен: выключено → белая → выключено → красная.
  static const List<SimScene> _sequence = <SimScene>[
    SimScene.off,
    SimScene.white,
    SimScene.off,
    SimScene.red,
  ];

  Duration get _offHold => switch (_speed) {
        _Speed.slow => const Duration(milliseconds: 2500),
        _Speed.medium => const Duration(milliseconds: 1200),
        _Speed.fast => const Duration(milliseconds: 600),
      };

  Duration get _flashHold => switch (_speed) {
        _Speed.slow => const Duration(milliseconds: 700),
        _Speed.medium => const Duration(milliseconds: 250),
        _Speed.fast => const Duration(milliseconds: 120),
      };

  // Случайная длительность вокруг базовой: base * [lo..hi].
  Duration _jitter(Duration base, double lo, double hi) => Duration(
        milliseconds:
            (base.inMilliseconds * (lo + _rng.nextDouble() * (hi - lo))).round(),
      );

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await _source.load();
      setState(() => _message = 'Нажми «Старт».');
    } on Object catch (e) {
      setState(() => _message = 'Не удалось загрузить картинки: $e');
    }
  }

  void _startScan() {
    _cycleStep = 0;
    _flashWhite = 0;
    _flashRed = 0;
    setState(() {
      _scanning = true;
      _message = 'Мигание…';
    });
    _runCycleStep();
  }

  void _stopScan() {
    _cycleTimer?.cancel();
    _cycleTimer = null;
    _source.setScene(SimScene.off);
    setState(() {
      _scanning = false;
      _message = 'Остановлено.';
    });
  }

  void _runCycleStep() {
    if (!mounted) {
      return;
    }
    final SimScene scene;
    final Duration hold;
    if (_random) {
      // Чётные шаги — «выключено», нечётные — случайная лампа; паузы рваные.
      if (_cycleStep.isEven) {
        scene = SimScene.off;
        hold = _jitter(_offHold, 0.5, 1.5);
      } else {
        scene = _rng.nextBool() ? SimScene.white : SimScene.red;
        hold = _jitter(_flashHold, 0.6, 1.8);
      }
    } else {
      scene = _sequence[_cycleStep % _sequence.length];
      hold = scene == SimScene.off ? _offHold : _flashHold;
    }
    _source.setScene(scene);
    setState(() {
      if (scene == SimScene.white) {
        _flashWhite++;
      } else if (scene == SimScene.red) {
        _flashRed++;
      }
    });
    _cycleTimer = Timer(hold, () {
      _cycleStep++;
      _runCycleStep();
    });
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Тестовая панель')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(child: Padding(
              padding: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _source.buildPreview(),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _sceneBadge(_source.scene),
                    ),
                  ],
                ),
              ),
            )),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SegmentedButton<bool>(
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment<bool>(value: false, label: Text('Фиксировано'), icon: Icon(Icons.repeat)),
                  ButtonSegment<bool>(value: true, label: Text('Случайно'), icon: Icon(Icons.shuffle)),
                ],
                selected: <bool>{_random},
                onSelectionChanged: (Set<bool> s) => setState(() => _random = s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SegmentedButton<_Speed>(
                segments: const <ButtonSegment<_Speed>>[
                  ButtonSegment<_Speed>(value: _Speed.slow, label: Text('Медленно')),
                  ButtonSegment<_Speed>(value: _Speed.medium, label: Text('Средне')),
                  ButtonSegment<_Speed>(value: _Speed.fast, label: Text('Быстро')),
                ],
                selected: <_Speed>{_speed},
                onSelectionChanged: (Set<_Speed> s) => setState(() => _speed = s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _scanning ? _stopScan : _startScan,
                  style: FilledButton.styleFrom(
                    backgroundColor: _scanning ? Colors.redAccent : Colors.teal,
                  ),
                  icon: Icon(_scanning ? Icons.stop : Icons.play_arrow),
                  label: Text(_scanning ? 'Стоп' : 'Старт'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  _counter('БЕЛАЯ мигнула', _flashWhite, Colors.white),
                  _counter('КРАСНАЯ мигнула', _flashRed, Colors.redAccent),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                _message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _counter(String label, int value, Color color) => Column(
        children: <Widget>[
          Text('$value',
              style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );

  Widget _sceneBadge(SimScene scene) {
    final (String text, Color color) = switch (scene) {
      SimScene.off => ('ВЫКЛ', Colors.grey),
      SimScene.white => ('БЕЛАЯ ГОРИТ', Colors.white),
      SimScene.red => ('КРАСНАЯ ГОРИТ', Colors.redAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}

/// Скорость перелистывания сцен.
enum _Speed { slow, medium, fast }
