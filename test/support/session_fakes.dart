import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Size, SizedBox, Widget;
import 'package:lamp_detection/lamp_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'synthetic_scene.dart';

/// Сборка сессии на фейках: тесты проверяют не камеру и не диск, а решения
/// сессии — что калибровка переживает загрузку, сбрасывается по смене света и
/// не переживает сдвига рамок.
///
/// Кадр подаётся вручную, поэтому в тесте видно ровно то, что в нём лежит:
/// яркость поля и метки экспозиции. Признаки считаются настоящим экстрактором,
/// чтобы проверка не расходилась со стендом.

/// Источник кадров по команде теста.
class TestFrameSource implements FrameSource {
  final StreamController<RawLampFrame> _frames =
      StreamController<RawLampFrame>.broadcast(sync: true);
  final StreamController<FrameSourceStatus> _status =
      StreamController<FrameSourceStatus>.broadcast(sync: true);

  @override
  Stream<RawLampFrame> get frames => _frames.stream;

  @override
  Stream<FrameSourceStatus> get status => _status.stream;

  @override
  bool get isRunning => true;

  @override
  Size? get previewSize => const Size(64, 64);

  @override
  FrameMapping get mapping => FrameMapping.identity;

  @override
  Widget buildPreview() => const SizedBox.shrink();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _frames.close();
    await _status.close();
  }

  void emit(RawLampFrame frame) => _frames.add(frame);
}

/// Хранилище в памяти: нужно, чтобы видеть, сколько событий реально создано.
class TestEventRepository implements EventRepository {
  final List<HitEvent> saved = <HitEvent>[];

  @override
  Future<void> save(HitEvent event) async => saved.add(event);

  @override
  Future<List<HitEvent>> history(String sessionId) async => saved;

  @override
  Future<List<HitEvent>> pending() async => const <HitEvent>[];

  @override
  Future<List<StoredEvent>> eventsWithStatus(String sessionId) async =>
      const <StoredEvent>[];

  @override
  Future<void> markSent(String eventId) async {}

  @override
  Future<void> markFailed(String eventId) async {}

  @override
  Future<void> resetSession(String sessionId) async {}

  @override
  Future<void> dispose() async {}
}

/// Кадр 64×64: поле яркостью [luma] при свете [exposureNs]/[gain].
///
/// Цветности в нём нет намеренно: проверяется не оттенок, а само решение
/// сессии по меткам экспозиции.
RawLampFrame sensorFrame({
  required int index,
  required int luma,
  int? exposureNs,
  double? gain,
}) {
  final Uint8List plane = Uint8List(64 * 64)..fillRange(0, 64 * 64, luma);
  return RawLampFrame(
    receivedAt: DateTime.fromMillisecondsSinceEpoch(index * 33),
    width: 64,
    height: 64,
    format: PixelFormatKind.yuv420,
    luma: plane,
    lumaStride: 64,
    exposureTimeNs: exposureNs,
    sensorSensitivity: gain,
  );
}

/// Кадр BGRA 64×64 с настоящими пятнами света в рамках [RoiLayout.defaults]:
/// белая лампа горит, если [whiteOn], красная — если [redOn]. Это единственный
/// способ проверить конвейер от пикселя до события, не требуя телефона.
RawLampFrame pixelFrame({
  required int index,
  bool whiteOn = false,
  bool redOn = false,
  int brightness = 240,
}) {
  final Uint8List pixels = Uint8List(64 * 64 * 4);
  if (whiteOn) {
    _fillRoi(pixels, RoiLayout.defaults.white, brightness);
  }
  if (redOn) {
    _fillRoi(pixels, RoiLayout.defaults.red, brightness);
  }
  return RawLampFrame(
    receivedAt: DateTime.fromMillisecondsSinceEpoch(index * 33),
    width: 64,
    height: 64,
    format: PixelFormatKind.bgra8888,
    pixels: pixels,
    rowStride: 64 * 4,
    pixelStride: 4,
  );
}

void _fillRoi(Uint8List pixels, LampRoi roi, int brightness) {
  final int x0 = (roi.left * 64).round();
  final int x1 = ((roi.left + roi.width) * 64).round();
  final int y0 = (roi.top * 64).round();
  final int y1 = ((roi.top + roi.height) * 64).round();
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      final int i = (y * 64 + x) * 4;
      pixels[i] = brightness;
      pixels[i + 1] = brightness;
      pixels[i + 2] = brightness;
      pixels[i + 3] = 255;
    }
  }
}

/// Та же сцена, но с другим светом — ровно тем, что калибровка обязана
/// не пережить.
LampFrame lit(LampFrame frame, {int? exposureNs, double? gain}) => LampFrame(
  timestamp: frame.timestamp,
  white: frame.white,
  red: frame.red,
  whiteRing: frame.whiteRing,
  redRing: frame.redRing,
  exposureTimeNs: exposureNs ?? frame.exposureTimeNs,
  sensorSensitivity: gain ?? frame.sensorSensitivity,
);

/// Калибровка в три состояния, снятая при свете [exposureNs]/[gain] — ровно так,
/// как её набирает стенд, только без камеры.
///
/// Способ счёта назван прямо: по умолчанию конфиг был бы HSV, а рабочий
/// способ по умолчанию теперь именно он (журнал 46). Синтетическая сцена
/// измеряет только яркость, цветовых рядов в ней нет, и HSV-калибровка такой
/// набор отвергает.
LampBaseline calibratedBaseline({
  int exposureNs = 20000000,
  double gain = 100,
  LampConfig config =
      const LampConfig(liveReference: false, hsvReference: false),
}) {
  const Scene scene = Scene();
  final LampDetector detector = LampDetector(config);
  int index = 0;
  for (final CalibrationStep step in CalibrationStep.mandatory) {
    for (int k = 0; k < config.calibrationFrames; k++, index++) {
      final LampFrame frame = switch (step) {
        CalibrationStep.background => scene.off(index: index),
        CalibrationStep.whiteOn => scene.both(white: scene.whiteOn, index: index),
        CalibrationStep.redOn => scene.both(red: scene.redOn, index: index),
        CalibrationStep.bothOn => scene.both(
          white: scene.whiteOn,
          red: scene.redOn,
          index: index,
        ),
      };
      detector.addCalibrationFrame(
        lit(frame, exposureNs: exposureNs, gain: gain),
      );
    }
  }
  return detector.baseline!;
}

/// Сессия на фейках с загруженной калибровкой и запущенным потоком кадров.
class TestRig {
  TestRig._(this.session, this.source, this.storage);

  final DetectionSession session;
  final TestFrameSource source;
  final TestEventRepository storage;

  /// Калибровка [baseline] лежит в настройках, сессия её загружает и стартует —
  /// ровно так, как на стенде, только без камеры и без диска.
  ///
  /// [config] по умолчанию — режим эталонов: под подставную калибровку
  /// (`calibratedBaseline`) годится только он, а способ по умолчанию теперь HSV
  /// (журнал 46), поэтому его приходится называть здесь прямо.
  static Future<TestRig> withCalibration(
    LampBaseline baseline, {
    LampConfig config =
        const LampConfig(liveReference: false, hsvReference: false),
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await SettingsStore(prefs).writeBaseline(baseline);

    final TestFrameSource source = TestFrameSource();
    final TestEventRepository storage = TestEventRepository();
    final DetectionSession session = DetectionSession(
      source: source,
      repository: storage,
      sender: MockHitEventSender(),
      settings: SettingsStore(prefs),
      csvRecorder: FeatureCsvRecorder(directory: Directory.systemTemp),
      config: config,
    );
    await session.loadSettings();
    await session.start();
    return TestRig._(session, source, storage);
  }
}
