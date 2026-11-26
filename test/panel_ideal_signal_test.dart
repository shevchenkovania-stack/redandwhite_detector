// Идеальный сигнал панели (sim_app home_page.dart: _resetRule/_idealBaseline/
// _idealBox/_frameFor/_advanceRule) против ТЕКУЩЕГО детектора в эталонном
// режиме. Тест-регресс на 2ccfb1b/79c29fd: панель строила калибровку только из
// whiteFrac/redFrac, а вектор решения — только из яркостей, поэтому эталоны
// были нулевыми, `LampResponseModel.isValid == false` и `evaluate` падал с
// StateError. Теперь идеальный сигнал панели построен на яркостях.
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/src/detection/hit_state_machine.dart';
import 'package:lamp_detection/src/detection/lamp_detector.dart';
import 'package:lamp_detection/src/detection/response_model.dart';
import 'package:lamp_detection/src/models/frame_features.dart';
import 'package:lamp_detection/src/models/hit_event.dart';
import 'package:lamp_detection/src/models/lamp_config.dart';

void main() {
  test('идеальный сигнал панели считается эталонным режимом один в один', () {
    const double liveWhiteDeltaFrac = 0.12;
    const double liveRedDeltaFrac = 0.42;
    final int calibrationFrames = LampConfig().calibrationFrames;

    // Точная копия _idealBox из home_page.dart: фон — равномерные рамки 200,
    // при горении измеренная доля насыщается в 255; p90 упирается в 255,
    // если засвечено >= 10% рамки.
    FrameFeatures box({
      double whiteFrac = 0,
      double redFrac = 0,
      double litFrac = 0,
    }) =>
        FrameFeatures(
          meanY: 200.0 + litFrac * (255.0 - 200.0),
          p90Luma: litFrac >= 0.10 ? 255.0 : 200.0,
          sampleCount: 100,
          whiteFrac: whiteFrac,
          redFrac: redFrac,
        );
    CalibrationState state({
      double whiteFrac = 0,
      double redFrac = 0,
      double whiteLit = 0,
      double redLit = 0,
    }) =>
        // σ = 0: FrameFeatures хранит σ в полях meanY/p90Luma, поэтому
        // «та же рамка» (box()) означало бы σ = 200 и ON-уровень уехал бы в
        // 21.7 вместо 0.6.
        CalibrationState(
          white: box(whiteFrac: whiteFrac, litFrac: whiteLit),
          red: box(redFrac: redFrac, litFrac: redLit),
          whiteSigma: FrameFeatures.zero,
          redSigma: FrameFeatures.zero,
          frameCount: calibrationFrames,
        );
    final LampBaseline baseline = LampBaseline(
      background: state(),
      whiteOn: state(
        whiteFrac: liveWhiteDeltaFrac,
        whiteLit: liveWhiteDeltaFrac,
      ),
      redOn: state(redFrac: liveRedDeltaFrac, redLit: liveRedDeltaFrac),
      capturedAtMs: 0,
    );

    // Способ назван прямо: по умолчанию он теперь HSV (журнал 46), а проверка
    // именно про эталонный режим.
    final LampConfig config = LampConfig(
      onConfirmFrames: 2,
      offConfirmFrames: 3,
      liveReference: false,
      hsvReference: false,
    );
    final LampDetector detector = LampDetector(config)..setBaseline(baseline);
    // До фикса здесь было isCalibrated=false и evaluate кидал StateError.
    expect(detector.isCalibrated, isTrue);
    expect(detector.canEvaluate, isTrue);
    final LampResponseModel? model = detector.model;
    expect(model, isNotNull);
    expect(model!.isValid, isTrue);
    expect(model.whiteOnLevel(config.hitFraction), closeTo(0.6, 1e-9));
    expect(model.redOnLevel(config.hitFraction), closeTo(0.6, 1e-9));

    final HitStateMachine machine =
        HitStateMachine(sessionId: 'panel-rule', idGenerator: () => 'rule');
    int ruleW = 0;
    int ruleR = 0;
    int clockMs = 0;

    // 0 = off, 1 = white, 2 = red — как SimScene панели. Тот же цикл, что
    // _advanceRule: период 100 мс (10 к/с), frames = max(1, (hold/100).round()).
    void feed(int scene, int holdMs) {
      final int frames = (holdMs / 100).round() < 1 ? 1 : (holdMs / 100).round();
      for (int i = 0; i < frames; i++) {
        clockMs += 100;
        final DateTime t = DateTime.fromMillisecondsSinceEpoch(clockMs);
        final LampFrame frame = LampFrame(
          timestamp: t,
          white: box(
            whiteFrac: scene == 1 ? liveWhiteDeltaFrac : 0,
            litFrac: scene == 1 ? liveWhiteDeltaFrac : 0,
          ),
          red: box(
            redFrac: scene == 2 ? liveRedDeltaFrac : 0,
            litFrac: scene == 2 ? liveRedDeltaFrac : 0,
          ),
        );
        final LampEvaluation evaluation = detector.evaluate(frame);
        for (final HitEvent event in machine.onEvaluation(evaluation)) {
          if (event.color == HitColor.white) {
            ruleW++;
          } else {
            ruleR++;
          }
        }
      }
    }

    // Средняя скорость панели: off 1200, white 250, off 1200, red 250.
    feed(0, 1200);
    feed(1, 250);
    feed(0, 1200);
    feed(2, 250);
    expect(ruleW, 1);
    expect(ruleR, 1);

    // Длинное горение — штатный режим (критерий 3): красная гаснет, белая
    // включается и горит 30 с БЕЗ гашения. Новое событие включения ровно
    // одно (белый канал был OFF после паузы), а на самом горении счёт не
    // ползёт.
    feed(0, 1200);
    feed(1, 30250);
    expect(ruleW, 2);
    expect(ruleR, 1);

    // Гашение после горения — не событие.
    feed(0, 1200);
    expect(ruleW, 2);
    expect(ruleR, 1);
  });
}
