import 'dart:math' show Random;

import 'package:lamp_detection/lamp_detection.dart';

/// Синтетические сценарии для тестов детектора и автомата.
///
/// Значения подобраны так, чтобы соответствовать реальной записи: тёмная
/// подставка, белая лампа даёт пересвет (низкая sat), красная — рост яркости
/// и жёлто-белое ядро, при этом красит всю сцену (высокая sat в белой ROI).
class Scene {
  const Scene({
    this.whiteOff = const FrameFeatures(
      meanY: 60,
      brightFrac: 0.01,
      sat: 0.05,
      redDom: 5,
      coreEdgeDiff: 2,
      sampleCount: 400,
    ),
    this.redOff = const FrameFeatures(
      meanY: 50,
      brightFrac: 0.02,
      sat: 0.35,
      redDom: 40,
      coreEdgeDiff: 3,
      sampleCount: 400,
    ),
  });

  final FrameFeatures whiteOff;
  final FrameFeatures redOff;

  /// Белая горит: пересвеченное пятно, низкая насыщенность.
  FrameFeatures get whiteOn => const FrameFeatures(
    meanY: 200,
    brightFrac: 0.35,
    sat: 0.06,
    redDom: 4,
    coreEdgeDiff: 30,
    sampleCount: 400,
  );

  /// Красная горит: ярче на 40 относительно baseline + выросшее ядро.
  FrameFeatures get redOn => const FrameFeatures(
    meanY: 90,
    brightFrac: 0.05,
    sat: 0.6,
    redDom: 95,
    coreEdgeDiff: 28,
    sampleCount: 400,
  );

  /// Белая ROI под подсветкой красной: яркое пятно ЕСТЬ, но насыщенность
  /// высокая — белая лампа не должна сработать.
  FrameFeatures get whiteTintedByRed => const FrameFeatures(
    meanY: 150,
    brightFrac: 0.3,
    sat: 0.55,
    redDom: 70,
    coreEdgeDiff: 20,
    sampleCount: 400,
  );

  LampFrame both({
    FrameFeatures? white,
    FrameFeatures? red,
    required int index,
    int frameMs = 33,
  }) => LampFrame(
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + index * frameMs),
    white: white ?? whiteOff,
    red: red ?? redOff,
  );

  /// Кадр «обе выключены».
  LampFrame off({required int index, int frameMs = 33}) => both(index: index, frameMs: frameMs);

  /// Серия кадров подряд.
  List<LampFrame> sequence(int count, {int startIndex = 0, FrameFeatures? white, FrameFeatures? red, int frameMs = 33}) =>
      List<LampFrame>.generate(
        count,
        (int i) => both(index: startIndex + i, white: white, red: red, frameMs: frameMs),
      );

  /// Кадр с шумом яркости вокруг baseline.
  LampFrame noisy({required int index, required double jitterY, double jitterBright = 0}) {
    final Random rnd = Random(index);
    final double noise = (rnd.nextDouble() - 0.5) * 2 * jitterY;
    final double brightNoise = (rnd.nextDouble() - 0.5) * 2 * jitterBright;
    return both(
      index: index,
      white: FrameFeatures(
        meanY: whiteOff.meanY + noise,
        brightFrac: (whiteOff.brightFrac + brightNoise).clamp(0.0, 1.0),
        sat: whiteOff.sat,
        redDom: whiteOff.redDom,
        coreEdgeDiff: whiteOff.coreEdgeDiff,
        sampleCount: 400,
      ),
      red: FrameFeatures(
        meanY: redOff.meanY - noise,
        brightFrac: redOff.brightFrac,
        sat: redOff.sat,
        redDom: redOff.redDom,
        coreEdgeDiff: redOff.coreEdgeDiff,
        sampleCount: 400,
      ),
    );
  }
}

/// Прогон кадров через детектор + автомат, как это делает живая сессия.
class Harness {
  Harness({LampConfig? config, Scene? scene})
    : config = config ?? const LampConfig(),
      scene = scene ?? const Scene() {
    detector = LampDetector(this.config);
    machine = HitStateMachine(sessionId: 'test-session', idGenerator: _ids.next);
    calibrate();
  }

  final LampConfig config;
  final Scene scene;
  late final LampDetector detector;
  late final HitStateMachine machine;
  final _IdGenerator _ids = _IdGenerator();

  int get ambiguousFrames => detector.ambiguousFrames;

  /// Калибровка «обе выключены» по [LampConfig.calibrationFrames] кадров.
  void calibrate() {
    for (int i = 0; i < config.calibrationFrames; i++) {
      detector.addCalibrationFrame(scene.off(index: i));
    }
  }

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
    final int from = startIndex ?? config.calibrationFrames;
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
    final int from = startIndex ?? config.calibrationFrames;
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
