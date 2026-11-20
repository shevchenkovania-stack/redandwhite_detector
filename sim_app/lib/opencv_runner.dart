import 'dart:async';
import 'dart:io';

import 'package:lamp_detection/lamp_detection.dart';

import 'opencv_features.dart';
import 'opencv_shadow.dart';

/// Один отрезок прогона сравнения: сколько кадров держать какую сцену.
///
/// Имя сцены — строка, а не enum панели: файл сравнения не должен зависеть от
/// виджетов, иначе его нельзя запустить ни в консоли, ни в тесте.
class ShadowPlanStep {
  const ShadowPlanStep(this.scene, this.frames);

  /// Имя сцены, которое понимает источник картинок (`off`, `white`, `red`).
  final String scene;

  /// Сколько кадров прогнать в этом состоянии.
  final int frames;
}

/// Прогон конвейера с тенью на OpenCV.
///
/// Задача одна: получить НАСТОЯЩИЕ числа обоих способов на одних и тех же
/// кадрах. Делается это единственно честным порядком — кадры гонит
/// [DetectionSession], решение принимает рабочий конвейер, а OpenCV подключён
/// к нему как [ShadowProbe], то есть физически не может ни на что повлиять.
///
/// Всё остальное — подделки вместо камеры: [MemorySettingsStore] вместо
/// сохранённых настроек, [MemoryEventRepository] вместо базы, картинки
/// симулятора вместо стенда. Ни одна из них не входит в решение.
class OpenCvShadowRunner {
  OpenCvShadowRunner({
    required this.source,
    required this.config,
    this.roi = RoiLayout.defaults,
    this.blurKernelSize = 5,
    this.reportFrames = 40,
    this.setScene,
    this.onLine,
  });

  /// Источник кадров — обычно `SimFrameSource` панели.
  final FrameSource source;

  /// Те же пороги и геометрия, чем решает рабочий конвейер.
  final LampConfig config;

  final RoiLayout roi;

  /// Как сглаживать кадр в OpenCV.
  final int blurKernelSize;

  /// Сколько кадров копить и печатать в таблице.
  final int reportFrames;

  /// Переключить картинку симулятора на сцену с этим именем.
  final void Function(String scene)? setScene;

  /// Куда писать строки отчёта: в панели — на экран и в лог, в консоли — в
  /// stdout.
  final void Function(String line)? onLine;

  final List<String> _lines = <String>[];
  FeatureExtractor? _working;
  OpenCvShadowInstrument? _instrument;

  /// Рабочий экстрактор, которым тень пересчитывает кадр для сравнения.
  FeatureExtractor get working => _working ??= FeatureExtractor(config);

  /// Измеритель-накопитель. Создаётся один раз на прогон.
  OpenCvShadowInstrument get instrument =>
      _instrument ??= OpenCvShadowInstrument(
        extractor: OpenCvFeatureExtractor(
          config: config,
          blurKernelSize: blurKernelSize,
        ),
        workingExtractor: working,
        maxPairs: reportFrames,
        onReport: (String report) => _emit(report),
      );

  /// Прогон по плану через полноценную сессию.
  ///
  /// Кадры идут через [DetectionSession], события считает автомат, OpenCV
  /// стоит тенью. Возвращает число событий и текст сравнения: по первому
  /// видно, что тень не изменила решение, по второму — насколько расходится
  /// фотометрия.
  Future<ShadowRunResult> runPlan(
    List<ShadowPlanStep> plan, {
    Duration between = const Duration(milliseconds: 33),
  }) async {
    final OpenCvShadowInstrument shadow = instrument;
    final MemoryEventRepository storage = MemoryEventRepository();
    final DetectionSession session = DetectionSession(
      source: source,
      repository: storage,
      sender: MockHitEventSender(),
      settings: MemorySettingsStore(),
      csvRecorder: FeatureCsvRecorder(directory: Directory.systemTemp),
      config: config,
      roi: roi,
    );
    session.shadowProbe = shadow.observe;
    int events = 0;
    final StreamSubscription<HitEvent> sub = session.hits.listen(
      (HitEvent event) => events++,
    );
    await session.loadSettings();
    await session.start();
    for (final ShadowPlanStep step in plan) {
      setScene?.call(step.scene);
      for (int i = 0; i < step.frames; i++) {
        await Future<void>.delayed(between);
      }
    }
    // Кадр обрабатывается асинхронно: даём очереди доработать хвост.
    await _drain();
    await session.stop();
    await sub.cancel();
    final String report = shadow.report();
    _emit(report);
    await session.dispose();
    return ShadowRunResult(events: events, report: report, instrument: shadow);
  }

  /// Прогон готовых кадров без автомата: только фотометрия. Нужен, когда надо
  /// быстро сверить числа на наборе картинок, не включая решение.
  String runFrames(
    List<RawLampFrame> frames, {
    RoiLayout? roiOverride,
  }) {
    final OpenCvShadowInstrument shadow = instrument;
    final RoiLayout where = roiOverride ?? roi;
    final FrameMapping mapping = source.mapping;
    for (final RawLampFrame frame in frames) {
      shadow.addDirect(frame, where, mapping);
    }
    final String report = shadow.report();
    _emit(report);
    return report;
  }

  /// Все строки, которые прогон выдал. Панель показывает их как есть.
  List<String> get lines => List<String>.unmodifiable(_lines);

  void dispose() {
    _instrument?.dispose();
    _instrument = null;
    _working = null;
  }

  void _emit(String text) {
    for (final String line in text.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      _lines.add(line);
      onLine?.call(line);
    }
  }

  /// Ждать, пока очередь событий прогона разберётся. Простой таймер, а не
  /// `pumpEventQueue`: вне тестового биндинга последнего нет.
  Future<void> _drain() async {
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

/// Итог прогона с тенью.
class ShadowRunResult {
  const ShadowRunResult({
    required this.events,
    required this.report,
    required this.instrument,
  });

  /// Сколько событий создал автомат. Тень на это число повлиять не может.
  final int events;

  /// Полный текст сравнения.
  final String report;

  final OpenCvShadowInstrument instrument;

  /// Отчёт для консоли: сначала вывод, потом цифры.
  void printTo(StringSink sink) => sink.write(report);
}

/// Настройки в памяти. Нужны, чтобы прогон сравнения не зависел от плагина
/// сохранённых настроек: ни в тесте, ни в консоли его держать не на чем.
class MemorySettingsStore implements SettingsStore {
  LampBaseline? _baseline;
  LampConfig? _config;
  RoiLayout? _roi;
  String? _sessionId;

  @override
  Future<void> clearBaseline() async => _baseline = null;

  @override
  LampBaseline? readBaseline() => _baseline;

  @override
  LampConfig? readConfig() => _config;

  @override
  RoiLayout? readRoi() => _roi;

  @override
  String? readSessionId() => _sessionId;

  @override
  Future<void> writeBaseline(LampBaseline baseline) async =>
      _baseline = baseline;

  @override
  Future<void> writeConfig(LampConfig config) async => _config = config;

  @override
  Future<void> writeRoi(RoiLayout roi) async => _roi = roi;

  @override
  Future<void> writeSessionId(String sessionId) async =>
      _sessionId = sessionId;
}

/// Хранилище событий в памяти: нужно, чтобы видеть, сколько событий реально
/// создал автомат.
class MemoryEventRepository implements EventRepository {
  final List<HitEvent> saved = <HitEvent>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<List<StoredEvent>> eventsWithStatus(String sessionId) async =>
      saved
          .map(
            (HitEvent e) => StoredEvent(
              event: e,
              status: DeliveryStatus.sent,
              attempts: 1,
            ),
          )
          .toList(growable: false);

  @override
  Future<List<HitEvent>> history(String sessionId) async => saved;

  @override
  Future<void> markFailed(String eventId) async {}

  @override
  Future<void> markSent(String eventId) async {}

  @override
  Future<List<HitEvent>> pending() async => const <HitEvent>[];

  @override
  Future<void> resetSession(String sessionId) async => saved.clear();

  @override
  Future<void> save(HitEvent event) async => saved.add(event);
}
