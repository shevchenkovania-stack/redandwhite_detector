import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../camera/frame_source.dart';
import '../delivery/hit_event_sender.dart';
import '../detection/feature_extractor.dart';
import '../detection/hit_state_machine.dart';
import '../detection/lamp_detector.dart';
import '../detection/lamp_locator.dart';
import '../diagnostics/diagnostics_collector.dart';
import '../diagnostics/feature_csv_recorder.dart';
import '../models/frame_features.dart';
import '../models/hit_event.dart';
import '../models/lamp_config.dart';
import '../models/roi.dart';
import '../storage/event_repository.dart';
import 'settings_store.dart';

/// Всё, что нужно UI про состояние сессии.
class LampStatus {
  const LampStatus({
    required this.running,
    required this.calibrating,
    required this.calibration,
    required this.isCalibrated,
    required this.whiteLit,
    required this.redLit,
    required this.whiteHits,
    required this.redHits,
    required this.sessionId,
    required this.recordingCsv,
    required this.state,
    this.csvPath,
  });

  static const LampStatus initial = LampStatus(
    running: false,
    calibrating: false,
    calibration: CalibrationProgress(collected: 0, needed: LampConfig.defaultCalibrationFrames),
    isCalibrated: false,
    whiteLit: false,
    redLit: false,
    whiteHits: 0,
    redHits: 0,
    sessionId: '',
    recordingCsv: false,
    state: LampSessionState.idle,
  );

  final bool running;
  final bool calibrating;
  final CalibrationProgress calibration;
  final bool isCalibrated;
  final bool whiteLit;
  final bool redLit;
  final int whiteHits;
  final int redHits;
  final String sessionId;
  final bool recordingCsv;
  final LampSessionState state;
  final String? csvPath;

  String get whiteStatus => whiteLit ? 'ON' : 'OFF';
  String get redStatus => redLit ? 'ON' : 'OFF';
}

/// Склеивает источник кадров, извлечение признаков, детектор, автомат,
/// хранилище, доставку и диагностику. Единственная точка входа для приложения.
class DetectionSession extends ChangeNotifier {
  DetectionSession({
    required this.source,
    required this.repository,
    required this.sender,
    required this.settings,
    required this.csvRecorder,
    LampConfig config = const LampConfig(),
    RoiLayout roi = RoiLayout.defaults,
    DiagnosticsCollector? diagnostics,
    String? sessionId,
  }) : _extractor = FeatureExtractor(config),
       _detector = LampDetector(config),
       _machine = HitStateMachine(sessionId: sessionId ?? const Uuid().v4()),
       diagnostics = diagnostics ?? DiagnosticsCollector(),
       _config = config,
       _roi = roi {
    this.diagnostics.isolateThresholdMs = config.analysisIsolateThresholdMs;
  }

  /// Сколько сообщений об ошибках держать для панели.
  static const int maxStoredErrors = 50;

  final FrameSource source;
  final EventRepository repository;
  final HitEventSender sender;
  final SettingsStore settings;
  final FeatureCsvRecorder csvRecorder;
  final DiagnosticsCollector diagnostics;

  final FeatureExtractor _extractor;
  final LampDetector _detector;
  final HitStateMachine _machine;

  LampConfig _config;
  RoiLayout _roi;

  final StreamController<HitEvent> _hits = StreamController<HitEvent>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final List<String> _lastErrors = <String>[];

  StreamSubscription<RawLampFrame>? _framesSub;
  StreamSubscription<FrameSourceStatus>? _statusSub;
  Completer<LampBaseline>? _calibrationCompleter;
  Future<void>? _delivery;

  bool _busy = false;
  bool _running = false;
  bool _calibrating = false;
  bool _recordingCsv = false;
  bool _whiteLit = false;
  bool _redLit = false;
  bool _disposed = false;
  int _whiteHits = 0;
  int _redHits = 0;
  String _lastSignature = '';
  RawLampFrame? _lastFrame;
  LampFrame? _lastLampFrame;
  LampEvaluation? _lastEvaluation;

  /// События, созданные детектором. Подписываться до [start].
  Stream<HitEvent> get hits => _hits.stream;

  /// Ошибки камеры и обработки: приложение не падает, всё сюда.
  Stream<String> get errors => _errors.stream;

  List<String> get lastErrors => List<String>.unmodifiable(_lastErrors);

  RoiLayout get roi => _roi;
  LampConfig get config => _config;
  bool get isRunning => _running;
  bool get isCalibrated => _detector.isCalibrated;
  String get sessionId => _machine.sessionId;
  int get whiteHits => _whiteHits;
  int get redHits => _redHits;
  LampBaseline? get baseline => _detector.baseline;

  /// Признаки последнего обработанного кадра по обеим рамкам — для «Расшифровки».
  LampFrame? get lastFeatures => _lastLampFrame;

  /// Оценка последнего кадра (score/состояние/неоднозначность). Null, пока
  /// детектор не откалиброван и кадр считается вхолостую.
  LampEvaluation? get lastEvaluation => _lastEvaluation;

  /// История score по времени — для графика «повторное попадание».
  List<ScorePoint> get scoreHistory => diagnostics.scores;

  LampStatus get status => LampStatus(
    running: _running,
    calibrating: _calibrating,
    calibration: _detector.calibrationProgress,
    isCalibrated: _detector.isCalibrated,
    whiteLit: _whiteLit,
    redLit: _redLit,
    whiteHits: _whiteHits,
    redHits: _redHits,
    sessionId: sessionId,
    recordingCsv: _recordingCsv,
    state: _machine.state,
    csvPath: csvRecorder.filePath,
  );

  /// Загружает сохранённые ROI, baseline и пороги. Вызывать до [start].
  Future<void> loadSettings() async {
    _roi = settings.readRoi() ?? _roi;
    final LampConfig? storedConfig = settings.readConfig();
    if (storedConfig != null) {
      _config = storedConfig;
      _extractor.config = storedConfig;
      _detector.config = storedConfig;
      diagnostics.isolateThresholdMs = storedConfig.analysisIsolateThresholdMs;
    }
    final LampBaseline? baseline = settings.readBaseline();
    if (baseline != null) {
      _detector.setBaseline(baseline);
    }
    final String? storedSession = settings.readSessionId();
    if (storedSession != null) {
      _machine.startSession(storedSession);
    }
    _notify(force: true);
  }

  /// Запуск: подписка на кадры + попытка отправить недоставанные события.
  Future<void> start() async {
    if (_running || _disposed) {
      return;
    }
    _statusSub ??= source.status.listen(_onSourceStatus);
    _framesSub ??= source.frames.listen(_onFrame);
    try {
      await source.start();
      _running = true;
      _notify(force: true);
    } on Object catch (e) {
      _report('Старт камеры: $e');
    }
    await deliverPending();
  }

  /// Полная остановка: поток кадров и камера освобождаются, повторный [start]
  /// работает без перезапуска приложения.
  Future<void> stop() async {
    _running = false;
    await _persistBaseline();
    await source.stop();
    await _framesSub?.cancel();
    await _statusSub?.cancel();
    _framesSub = null;
    _statusSub = null;
    if (_recordingCsv) {
      await csvRecorder.stop();
      _recordingCsv = false;
    }
    _notify(force: true);
  }

  /// Калибровка «обе выключены»: набирает [LampConfig.calibrationFrames]
  /// кадров и усредняет признаки каждой ROI.
  Future<LampBaseline> calibrate() {
    if (!_running) {
      return Future<LampBaseline>.error(StateError('Сессия не запущена: сначала Start'));
    }
    if (_calibrating) {
      return _calibrationCompleter!.future;
    }
    _calibrating = true;
    _detector.clearCalibration();
    _calibrationCompleter = Completer<LampBaseline>();
    _notify(force: true);
    return _calibrationCompleter!.future;
  }

  /// Воспроизведение записанного CSV без камеры: те же детектор и автомат.
  ///
  /// Если [baseline] не передан, калибровкой считаются первые
  /// [LampConfig.calibrationFrames] строк (так запись и ведётся: сначала кадры
  /// с выключенными лампами).
  Future<List<HitEvent>> replayCsv(String csvContent, {LampBaseline? baseline}) async {
    final List<FeatureCsvRow> rows = FeatureCsv.decode(csvContent);
    if (rows.isEmpty) {
      return const <HitEvent>[];
    }
    final LampDetector detector = LampDetector(_config);
    detector.setBaseline(baseline ?? _calibrateFrom(rows));
    final HitStateMachine machine = HitStateMachine(sessionId: 'replay');
    final List<HitEvent> events = <HitEvent>[];
    for (final FeatureCsvRow row in rows) {
      events.addAll(machine.onEvaluation(detector.evaluate(row.toLampFrame())));
    }
    return events;
  }

  LampBaseline _calibrateFrom(List<FeatureCsvRow> rows) {
    final int take = rows.length < _config.calibrationFrames
        ? rows.length
        : _config.calibrationFrames;
    final List<FeatureCsvRow> head = rows.take(take).toList();
    return LampBaseline(
      white: _mean(head.map((FeatureCsvRow r) => r.white)),
      red: _mean(head.map((FeatureCsvRow r) => r.red)),
      frameCount: head.length,
    );
  }

  static FrameFeatures _mean(Iterable<FrameFeatures> list) {
    final List<FrameFeatures> items = list.toList();
    double sum(double Function(FrameFeatures f) pick) =>
        items.fold<double>(0, (double acc, FrameFeatures f) => acc + pick(f)) / items.length;
    return FrameFeatures(
      meanY: sum((FrameFeatures f) => f.meanY),
      brightFrac: sum((FrameFeatures f) => f.brightFrac),
      sat: sum((FrameFeatures f) => f.sat),
      redDom: sum((FrameFeatures f) => f.redDom),
      coreEdgeDiff: sum((FrameFeatures f) => f.coreEdgeDiff),
      sampleCount: 0,
    );
  }

  void updateRoi(RoiLayout layout, {bool persist = false}) {
    _roi = layout;
    if (persist) {
      unawaited(settings.writeRoi(layout));
    }
    _notify(force: true);
  }

  /// Автоматический поиск зон ламп по последнему кадру и установка ROI.
  /// Возвращает найденный [RoiLayout] или null, если кадр ещё не пришёл
  /// (камера не запущена). Пороги/насычность берутся из текущего конфига.
  RoiLayout? autoLocateLamps({bool persist = true}) {
    final RawLampFrame? frame = _lastFrame;
    if (frame == null) {
      return null;
    }
    final RoiLayout layout =
        const LampLocator().locate(frame, _extractor, source.mapping, _config);
    updateRoi(layout, persist: persist);
    return layout;
  }

  Future<void> saveRoi() => settings.writeRoi(_roi);

  Future<void> saveCalibration() async {
    final LampBaseline? baseline = _detector.baseline;
    if (baseline != null) {
      await settings.writeBaseline(baseline);
    }
  }

  Future<void> saveConfig() => settings.writeConfig(_config);

  /// Смена порогов на лету (подбор по CSV).
  void applyConfig(LampConfig config) {
    _config = config;
    _extractor.config = config;
    _detector.config = config;
    diagnostics.isolateThresholdMs = config.analysisIsolateThresholdMs;
    _notify(force: true);
  }

  /// Принудительное соответствие превью <-> кадр (если авто-расчёт не угадал
  /// ориентацию сенсора на конкретном устройстве).
  void setFrameMapping(int quarterTurns, {bool mirror = false}) {
    final FrameSource target = source;
    if (target is FrameMappingControl) {
      (target as FrameMappingControl).setFrameMapping(quarterTurns, mirror: mirror);
    }
    _notify(force: true);
  }

  /// Новая сессия: новый sessionId, нумерация событий с 1, счётчики в нуль.
  Future<void> newSession() async {
    final String id = const Uuid().v4();
    _machine.startSession(id);
    _detector.resetTracking();
    _whiteHits = 0;
    _redHits = 0;
    _whiteLit = false;
    _redLit = false;
    diagnostics.resetCounters();
    await settings.writeSessionId(id);
    _notify(force: true);
  }

  /// Сброс счётчиков без смены сессии.
  void resetCounters() {
    _whiteHits = 0;
    _redHits = 0;
    _machine.reset();
    _detector.resetTracking();
    diagnostics.resetCounters();
    _notify(force: true);
  }

  /// Включает/выключает запись CSV признаков.
  Future<void> setRecordingCsv(bool on) async {
    if (on == _recordingCsv) {
      return;
    }
    _recordingCsv = on;
    if (on) {
      await csvRecorder.start(sessionId);
      _report('Запись CSV: ${csvRecorder.filePath}', isError: false);
    } else {
      await csvRecorder.stop();
      _report('CSV сохранён: ${csvRecorder.filePath}', isError: false);
    }
    _notify(force: true);
  }

  /// Защита от очереди кадров: если обработка идёт, кадр пропускается.
  void _onFrame(RawLampFrame frame) {
    diagnostics.onCameraFrame(frame.receivedAt);
    _lastFrame = frame;
    if (_busy) {
      diagnostics.onFrameDropped();
      return;
    }
    _busy = true;
    try {
      _processFrame(frame);
    } on Object catch (e) {
      _report('Обработка кадра: $e');
    } finally {
      _busy = false;
    }
  }

  void _processFrame(RawLampFrame frame) {
    diagnostics.beginAnalysis();

    final LampFrame lampFrame = _extractor.extract(frame, _roi, source.mapping);
    LampEvaluation? evaluation;
    List<HitEvent> events = const <HitEvent>[];

    if (_calibrating) {
      final LampBaseline? done = _detector.addCalibrationFrame(lampFrame);
      if (done != null) {
        _calibrating = false;
        unawaited(saveCalibration());
        _calibrationCompleter?.complete(done);
        _calibrationCompleter = null;
        _report('Калибровка завершена: ${done.frameCount} кадров', isError: false);
      }
    } else if (_detector.isCalibrated) {
      evaluation = _detector.evaluate(lampFrame);
      if (evaluation.ambiguous) {
        diagnostics.onAmbiguousFrame();
      }
      events = _machine.onEvaluation(evaluation);
      _whiteLit = evaluation.whiteLit;
      _redLit = evaluation.redLit;
    }

    _lastLampFrame = lampFrame;
    _lastEvaluation = evaluation;

    diagnostics.endAnalysis();
    diagnostics.onFrameProcessed(
      timestamp: lampFrame.timestamp,
      whiteScore: evaluation?.whiteScore ?? 0,
      redScore: evaluation?.redScore ?? 0,
      exposureTimeNs: lampFrame.exposureTimeNs,
      sensorSensitivity: lampFrame.sensorSensitivity,
    );

    if (_recordingCsv) {
      unawaited(
        csvRecorder.write(
          FeatureCsvRow(
            timestampMs: lampFrame.timestamp.millisecondsSinceEpoch,
            white: lampFrame.white,
            red: lampFrame.red,
            state: _machine.state.name,
          ),
        ),
      );
    }

    if (events.isNotEmpty) {
      unawaited(_handleEvents(events));
    }
    _notify();
  }

  /// События сначала пишутся в SQLite, потом идут в UI и в очередь доставки.
  Future<void> _handleEvents(List<HitEvent> events) async {
    final Stopwatch saveTimer = Stopwatch()..start();
    for (final HitEvent event in events) {
      try {
        await repository.save(event);
        diagnostics.onSaveLatency(saveTimer.elapsed);
        diagnostics.onEvent();
        if (event.color == HitColor.white) {
          _whiteHits++;
        } else {
          _redHits++;
        }
        _hits.add(event);
      } on Object catch (e) {
        _report('Сохранение события ${event.eventId}: $e');
      }
      saveTimer
        ..reset()
        ..start();
    }
    _notify(force: true);
    await deliverPending();
  }

  /// Последовательная отправка всех недоставанных событий. При первой же
  /// неудаче встаём: события остаются pending и уйдут при следующем запуске.
  Future<void> deliverPending() async {
    final Future<void>? inFlight = _delivery;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> task = _deliverLoop();
    _delivery = task;
    try {
      await task;
    } finally {
      _delivery = null;
    }
  }

  Future<void> _deliverLoop() async {
    while (!_disposed) {
      final List<HitEvent> pending;
      try {
        pending = await repository.pending();
      } on Object catch (e) {
        _report('Чтение pending: $e');
        return;
      }
      if (pending.isEmpty) {
        return;
      }
      for (final HitEvent event in pending) {
        try {
          final DeliveryResult result = await sender.send(event);
          if (!result.success) {
            await repository.markFailed(event.eventId);
            _report('Доставка ${event.eventId} не удалась: ${result.error}', isError: false);
            return;
          }
          await repository.markSent(event.eventId);
        } on Object catch (e) {
          await _safeMarkFailed(event.eventId);
          _report('Исключение доставки ${event.eventId}: $e');
          return;
        }
      }
    }
  }

  Future<void> _safeMarkFailed(String eventId) async {
    try {
      await repository.markFailed(eventId);
    } on Object catch (e) {
      _report('markFailed($eventId): $e');
    }
  }

  Future<void> _persistBaseline() async {
    try {
      await saveCalibration();
    } on Object catch (e) {
      _report('Сохранение калибровки: $e');
    }
  }

  void _onSourceStatus(FrameSourceStatus status) {
    _report(status.message, isError: status.isError);
  }

  void _report(String message, {bool isError = true}) {
    _lastErrors.insert(0, message);
    if (_lastErrors.length > maxStoredErrors) {
      _lastErrors.removeRange(maxStoredErrors, _lastErrors.length);
    }
    if (isError) {
      _errors.add(message);
    }
    debugPrint('[lamp_detection] $message');
  }

  /// 30 кадров в секунду — перерисовывать UI на каждый кадр бессмысленно:
  /// уведомляем только когда видимые значения реально изменились.
  void _notify({bool force = false}) {
    final LampStatus s = status;
    final String signature =
        '${s.running}|${s.calibrating}|${s.calibration.collected}|${s.isCalibrated}|'
        '${s.whiteLit}|${s.redLit}|${s.whiteHits}|${s.redHits}|${s.sessionId}|${s.recordingCsv}';
    if (!force && signature == _lastSignature) {
      return;
    }
    _lastSignature = signature;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stop();
    diagnostics.dispose();
    await _hits.close();
    await _errors.close();
    super.dispose();
  }
}
