import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Мгновенный снимок диагностики.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.cameraFps,
    required this.analysisFps,
    required this.avgAnalysisMs,
    required this.maxAnalysisMs,
    required this.droppedFrames,
    required this.framesProcessed,
    required this.eventCount,
    required this.ambiguousFrames,
    required this.avgSaveLatencyMs,
    required this.maxSaveLatencyMs,
    required this.exposureTimeNs,
    required this.sensorSensitivity,
    required this.needsIsolate,
  });

  static const DiagnosticsSnapshot empty = DiagnosticsSnapshot(
    cameraFps: 0,
    analysisFps: 0,
    avgAnalysisMs: 0,
    maxAnalysisMs: 0,
    droppedFrames: 0,
    framesProcessed: 0,
    eventCount: 0,
    ambiguousFrames: 0,
    avgSaveLatencyMs: 0,
    maxSaveLatencyMs: 0,
    exposureTimeNs: null,
    sensorSensitivity: null,
    needsIsolate: false,
  );

  final double cameraFps;
  final double analysisFps;
  final double avgAnalysisMs;
  final double maxAnalysisMs;
  final int droppedFrames;
  final int framesProcessed;
  final int eventCount;
  final int ambiguousFrames;
  final double avgSaveLatencyMs;
  final double maxSaveLatencyMs;

  /// Экспозиция последнего кадра: если значение дрейфует, автоэкспозиция не
  /// зафиксирована и baseline будет плыть.
  final int? exposureTimeNs;
  final double? sensorSensitivity;

  /// Среднее время анализа выше порога LampConfig.analysisIsolateThresholdMs.
  final bool needsIsolate;

  @override
  String toString() =>
      'camera=${cameraFps.toStringAsFixed(1)}fps analysis=${analysisFps.toStringAsFixed(1)}fps '
      'avg=${avgAnalysisMs.toStringAsFixed(2)}ms max=${maxAnalysisMs.toStringAsFixed(2)}ms '
      'dropped=$droppedFrames events=$eventCount ambiguous=$ambiguousFrames';
}

/// Одна точка графика score (режим «повторное попадание»).
class ScorePoint {
  const ScorePoint({required this.at, required this.white, required this.red});

  final DateTime at;
  final double white;
  final double red;
}

/// Сбор метрик и истории score. Отдаёт данные через ChangeNotifier, чтобы демо
/// перерисовывало панель диагностики без bloc/riverpod.
class DiagnosticsCollector extends ChangeNotifier {
  DiagnosticsCollector({this.windowSize = 60, this.historySize = 240, this.notifyInterval = const Duration(milliseconds: 200)});

  /// Сколько последних межкадровых интервалов учитывать для FPS.
  final int windowSize;
  final int historySize;
  final Duration notifyInterval;

  final Queue<DateTime> _cameraStamps = Queue<DateTime>();
  final Queue<DateTime> _analysisStamps = Queue<DateTime>();
  final List<ScorePoint> _scores = <ScorePoint>[];
  final Stopwatch _stopwatch = Stopwatch();

  double _totalAnalysisMs = 0;
  double _maxAnalysisMs = 0;
  int _analysisSamples = 0;
  double _totalSaveMs = 0;
  double _maxSaveMs = 0;
  int _droppedFrames = 0;
  int _framesProcessed = 0;
  int _eventCount = 0;
  int _ambiguousFrames = 0;
  int? _exposureTimeNs;
  double? _sensorSensitivity;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isolatedFlag = false;
  double _isolateThresholdMs = 8;

  List<ScorePoint> get scores => List<ScorePoint>.unmodifiable(_scores);
  int get droppedFrames => _droppedFrames;

  /// Порог «пора в изолят» берётся из LampConfig.
  set isolateThresholdMs(double value) => _isolateThresholdMs = value;

  DiagnosticsSnapshot get snapshot {
    final int n = _framesProcessed;
    final double avg = n == 0 ? 0 : _totalAnalysisMs / n;
    return DiagnosticsSnapshot(
      cameraFps: _fps(_cameraStamps),
      analysisFps: _fps(_analysisStamps),
      avgAnalysisMs: avg,
      maxAnalysisMs: _maxAnalysisMs,
      droppedFrames: _droppedFrames,
      framesProcessed: n,
      eventCount: _eventCount,
      ambiguousFrames: _ambiguousFrames,
      avgSaveLatencyMs: n == 0 ? 0 : _totalSaveMs / n,
      maxSaveLatencyMs: _maxSaveMs,
      exposureTimeNs: _exposureTimeNs,
      sensorSensitivity: _sensorSensitivity,
      needsIsolate: _isolatedFlag,
    );
  }

  static double _fps(Queue<DateTime> stamps) {
    if (stamps.length < 2) {
      return 0;
    }
    final Duration span = stamps.last.difference(stamps.first);
    if (span.inMicroseconds == 0) {
      return 0;
    }
    return (stamps.length - 1) * 1000000 / span.inMicroseconds;
  }

  /// Вызывается на каждый пришедший кадр камеры (до проверки _busy).
  void onCameraFrame(DateTime at) {
    _push(_cameraStamps, at, windowSize);
  }

  /// Кадр пропущен, потому что обработка ещё шла.
  void onFrameDropped() {
    _droppedFrames++;
  }

  void beginAnalysis() {
    _stopwatch
      ..reset()
      ..start();
  }

  void endAnalysis() {
    _stopwatch.stop();
    final double ms = _stopwatch.elapsedMicroseconds / 1000;
    _totalAnalysisMs += ms;
    _analysisSamples++;
    if (ms > _maxAnalysisMs) {
      _maxAnalysisMs = ms;
    }
    _isolatedFlag = _analysisSamples > 0 && _totalAnalysisMs / _analysisSamples > _isolateThresholdMs;
  }

  /// Вызывается после полной обработки кадра.
  void onFrameProcessed({
    required DateTime timestamp,
    required double whiteScore,
    required double redScore,
    int? exposureTimeNs,
    double? sensorSensitivity,
  }) {
    _framesProcessed++;
    _push(_analysisStamps, timestamp, windowSize);
    _scores.add(ScorePoint(at: timestamp, white: whiteScore, red: redScore));
    if (_scores.length > historySize) {
      _scores.removeRange(0, _scores.length - historySize);
    }
    if (exposureTimeNs != null) {
      _exposureTimeNs = exposureTimeNs;
    }
    if (sensorSensitivity != null) {
      _sensorSensitivity = sensorSensitivity;
    }
    _maybeNotify();
  }

  /// Время от обнаружения до сохранения события в SQLite.
  void onSaveLatency(Duration latency) {
    final double ms = latency.inMicroseconds / 1000;
    _totalSaveMs += ms;
    if (ms > _maxSaveMs) {
      _maxSaveMs = ms;
    }
  }

  void onEvent() => _eventCount++;

  void onAmbiguousFrame() => _ambiguousFrames++;

  /// Сброс счётчиков (Reset в демо). Кадровые FPS и история score обнуляются.
  void resetCounters() {
    _cameraStamps.clear();
    _analysisStamps.clear();
    _scores.clear();
    _totalAnalysisMs = 0;
    _maxAnalysisMs = 0;
    _analysisSamples = 0;
    _totalSaveMs = 0;
    _maxSaveMs = 0;
    _droppedFrames = 0;
    _framesProcessed = 0;
    _eventCount = 0;
    _ambiguousFrames = 0;
    _isolatedFlag = false;
    notifyListeners();
  }

  static void _push(Queue<DateTime> queue, DateTime at, int maxSize) {
    queue.addLast(at);
    while (queue.length > maxSize) {
      queue.removeFirst();
    }
  }

  void _maybeNotify() {
    final DateTime now = DateTime.now();
    if (now.difference(_lastNotify) < notifyInterval) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopwatch.stop();
    super.dispose();
  }
}
