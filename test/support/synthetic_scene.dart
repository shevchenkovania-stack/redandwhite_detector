import 'dart:math' show Random;

import 'package:lamp_detection/lamp_detection.dart';

/// Синтетические сцены для тестов детектора и автомата.
///
/// Кадр несёт ОБА способа измерения: прежние доли «своих» пикселей
/// (`whiteFrac`/`redFrac`) и яркость четырёх областей — ядра и ореола каждой
/// рамки. Второе обязательно, потому что решение по умолчанию принимается
/// пространственной картиной яркости, а калибровка без измеренных ореолов
/// отвергается как несущая ровно тот дефект, ради которого всё и затевалось.
///
/// Числа физически согласованы: вспышка поднимает СВОЮ рамку сильнее, чем
/// чужую. Это не украшение — если соседняя область ярче источника, никакого
/// пространственного различия не остаётся, и ни один способ источник там не
/// назовёт; такой случай проверяется отдельно и
/// обязан кончаться `AMBIGUOUS`, а не угадыванием.
///
/// По живым замерам: вспышка белой ΔwhiteFrac ≈ 0.35 и ΔЯ ≈ 140 уровней,
/// вспышка красной ΔredFrac ≈ 0.42, ореол растёт примерно в полтора раза
/// слабее колпака.
class Scene {
  const Scene({
    this.whiteOff = const FrameFeatures(
      meanY: 60,
      p90Luma: 80,
      sampleCount: 400,
      whiteFrac: 0.05,
      redFrac: 0.01,
    ),
    this.redOff = const FrameFeatures(
      meanY: 50,
      p90Luma: 70,
      sampleCount: 400,
      whiteFrac: 0.02,
      redFrac: 0.03,
    ),
  });

  final FrameFeatures whiteOff;
  final FrameFeatures redOff;

  /// Насколько ореол слабее колпака в тех же единицах яркости.
  static const double _haloFactor = 0.6;

  /// Белая горит: много «настоящих белых» пикселей (min(R,G,B) ≥ порога) и
  /// яркий колпак.
  FrameFeatures get whiteOn => const FrameFeatures(
    meanY: 200,
    p90Luma: 235,
    sampleCount: 400,
    whiteFrac: 0.40,
    redFrac: 0.01,
  );

  /// Красная горит: выросла доля красных пикселей в красной ROI.
  FrameFeatures get redOn => const FrameFeatures(
    meanY: 90,
    p90Luma: 120,
    sampleCount: 400,
    whiteFrac: 0.02,
    redFrac: 0.45,
  );

  /// Ореол своей лампы из её же колпака: поднимается на ту же долю, что и
  /// ядро, но слабее. Благодаря этому кадр остаётся согласованным и при шуме,
  /// и при провале внутри вспышки, и при частичном затенении.
  FrameFeatures _haloOf(FrameFeatures core, {required bool white}) {
    final FrameFeatures off = white ? whiteOff : redOff;
    // Фон ореола — те же уровни, что и у своего колпака, минус чуть более
    // тёмное окружение.
    final double ringOffY = white ? 40 : 35;
    final double ringOffP = white ? 55 : 48;
    return FrameFeatures(
      meanY: ringOffY + (core.meanY - off.meanY) * _haloFactor,
      p90Luma: ringOffP + (core.p90Luma - off.p90Luma) * _haloFactor,
      sampleCount: 900,
      whiteFrac: (off.whiteFrac * 0.5 + core.whiteFrac * 0.5).clamp(0.0, 1.0),
      redFrac: (off.redFrac * 0.5 + core.redFrac * 0.5).clamp(0.0, 1.0),
    );
  }

  LampFrame both({
    FrameFeatures? white,
    FrameFeatures? red,
    required int index,
    int frameMs = 33,
  }) {
    final FrameFeatures w = white ?? whiteOff;
    final FrameFeatures r = red ?? redOff;
    return LampFrame(
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + index * frameMs),
      white: w,
      red: r,
      whiteRing: _haloOf(w, white: true),
      redRing: _haloOf(r, white: false),
    );
  }

  /// Кадр «обе выключены».
  LampFrame off({required int index, int frameMs = 33}) => both(index: index, frameMs: frameMs);

  /// Серия кадров подряд.
  List<LampFrame> sequence(int count, {int startIndex = 0, FrameFeatures? white, FrameFeatures? red, int frameMs = 33}) =>
      List<LampFrame>.generate(
        count,
        (int i) => both(index: startIndex + i, white: white, red: red, frameMs: frameMs),
      );

  /// Кадр с шумом вокруг baseline: яркость и верх распределения гуляют вместе
  /// (так и есть на камере: шумит весь кадр, а не одна доля), доли белых и
  /// красных — на единицы процентов. Детектор обязан молчать.
  LampFrame noisy({required int index, required double jitterY}) {
    final Random rnd = Random(index);
    final double noise = (rnd.nextDouble() - 0.5) * 2 * jitterY;
    final double fracNoise = (rnd.nextDouble() - 0.5) * 2 * 0.01;
    return both(
      index: index,
      white: FrameFeatures(
        meanY: whiteOff.meanY + noise,
        p90Luma: whiteOff.p90Luma + noise,
        sampleCount: 400,
        whiteFrac: (whiteOff.whiteFrac + fracNoise).clamp(0.0, 1.0),
        redFrac: whiteOff.redFrac,
      ),
      red: FrameFeatures(
        meanY: redOff.meanY - noise,
        p90Luma: redOff.p90Luma - noise,
        sampleCount: 400,
        whiteFrac: redOff.whiteFrac,
        redFrac: (redOff.redFrac + fracNoise).clamp(0.0, 1.0),
      ),
    );
  }
}

/// Прогон кадров через детектор + автомат, как это делает живая сессия.
///
/// По умолчанию режим эталонов (`liveReference: false, hsvReference: false`):
/// эти тесты проверяют разложение отклика на измеренные эталоны и калибровку.
/// Живой отсчёт проверяется отдельно в `live_reference_test.dart` — он
/// намеренно не требует калибровки, и мешать два режима в одном сценарии значит
/// не проверить ни один.
///
/// `hsvReference: false` здесь обязателен, хотя раньше его не писали: рабочий
/// способ по умолчанию теперь HSV (журнал 46), а синтетическая сцена измеряет
/// только яркость — в цветовом режиме эти кадры ничего не дают.
class Harness {
  Harness({LampConfig? config, Scene? scene})
    : config =
          config ??
          const LampConfig(liveReference: false, hsvReference: false),
      scene = scene ?? const Scene() {
    detector = LampDetector(this.config);
    machine = HitStateMachine(sessionId: 'test-session', idGenerator: _ids.next);
    _detectFrom = calibrate();
  }

  final LampConfig config;
  final Scene scene;
  late final LampDetector detector;
  late final HitStateMachine machine;
  final _IdGenerator _ids = _IdGenerator();

  /// Первый кадр после калибровки: индексы обязаны идти дальше, иначе
  /// `detectedAt` двух разных шагов нельзя сравнить.
  late final int _detectFrom;
  int get detectFrom => _detectFrom;

  int get ambiguousFrames => detector.ambiguousFrames;

  /// Калибровка в три состояния, как на стенде: фон → держат белую → держат
  /// красную. Возвращает число скормленных кадров.
  int calibrate() {
    int i = 0;
    for (final CalibrationStep step in CalibrationStep.values) {
      for (int k = 0; k < config.calibrationFrames; k++, i++) {
        detector.addCalibrationFrame(calibrationFrame(step, index: i));
      }
    }
    return i;
  }

  /// Кадр шага калибровки: только нужная лампа горит, вторая — в фоне.
  LampFrame calibrationFrame(CalibrationStep step, {required int index}) =>
      switch (step) {
        CalibrationStep.background => scene.off(index: index),
        CalibrationStep.whiteOn => scene.both(white: scene.whiteOn, index: index),
        CalibrationStep.redOn => scene.both(red: scene.redOn, index: index),
      };

  /// Скормить кадр, вернуть порождённые события.
  List<HitEvent> feed(LampFrame frame) => machine.onEvaluation(detector.evaluate(frame));

  List<HitEvent> feedAll(Iterable<LampFrame> frames) =>
      frames.expand(feed).toList(growable: false);

  /// Белая горит [onFrames] кадров, затем пауза [offFrames] кадров.
  /// Отсчёт кадров продолжается после калибровки, как в живой сессии.
  List<HitEvent> whitePulse({
    int onFrames = 3,
    int offFrames = 5,
    int? startIndex,
  }) {
    final int from = startIndex ?? _detectFrom;
    final List<HitEvent> events = <HitEvent>[];
    events.addAll(feedAll(scene.sequence(onFrames, white: scene.whiteOn, startIndex: from)));
    events.addAll(feedAll(scene.sequence(offFrames, startIndex: from + onFrames)));
    return events;
  }

  List<HitEvent> redPulse({
    int onFrames = 3,
    int offFrames = 5,
    int? startIndex,
  }) {
    final int from = startIndex ?? _detectFrom;
    final List<HitEvent> events = <HitEvent>[];
    events.addAll(feedAll(scene.sequence(onFrames, red: scene.redOn, startIndex: from)));
    events.addAll(feedAll(scene.sequence(offFrames, startIndex: from + onFrames)));
    return events;
  }
}

/// Детерминированные id вместо uuid — чтобы тесты были читаемыми.
class _IdGenerator {
  int _n = 0;
  String next() => 'event-${++_n}';
}
