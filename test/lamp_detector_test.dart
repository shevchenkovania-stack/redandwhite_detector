// Положить в test/ пакета lamp_detection. Пути импортов — для layout lib/src/...
// (если у вас другие, поправьте).
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/src/detection/hit_state_machine.dart';
import 'package:lamp_detection/src/detection/lamp_detector.dart';
import 'package:lamp_detection/src/models/frame_features.dart';
import 'package:lamp_detection/src/models/lamp_config.dart';

FrameFeatures _f({double white = 0, double red = 0}) => FrameFeatures(
  meanY: 0,
  brightFrac: 0,
  sat: 0,
  redDom: 0,
  coreEdgeDiff: 0,
  sampleCount: 100,
  whiteFrac: white,
  redFrac: red,
);

DateTime _t = DateTime(2026, 1, 1);
LampFrame _frame({double white = 0, double red = 0}) {
  _t = _t.add(const Duration(milliseconds: 33));
  return LampFrame(timestamp: _t, white: _f(white: white), red: _f(red: red));
}

LampDetector _calibrated([LampConfig config = const LampConfig()]) {
  final LampDetector d = LampDetector(config);
  for (int i = 0; i < config.calibrationFrames; i++) {
    d.addCalibrationFrame(_frame());
  }
  expect(d.isCalibrated, isTrue);
  return d;
}

void main() {
  test('белая вспышка даёт ровно одно событие, а гашение снимает lit', () {
    final LampDetector d = _calibrated();
    final HitStateMachine m = HitStateMachine(sessionId: 's');
    int hits = 0;
    for (int i = 0; i < 6; i++) {
      hits += m.onEvaluation(d.evaluate(_frame(white: 0.4))).length;
    }
    expect(hits, 1);
    for (int i = 0; i < 6; i++) {
      m.onEvaluation(d.evaluate(_frame()));
    }
    expect(m.state, LampSessionState.idle);
  });

  test('красная: 10 % красных пикселей = score 2.0, событие одно', () {
    final LampDetector d = _calibrated();
    final HitStateMachine m = HitStateMachine(sessionId: 's');
    int hits = 0;
    for (int i = 0; i < 6; i++) {
      final LampEvaluation e = d.evaluate(_frame(red: 0.10));
      expect(e.redScore, closeTo(2.0, 1e-9));
      hits += m.onEvaluation(e).length;
    }
    expect(hits, 1);
  });

  test('нестабильный фон при калибровке отвергается', () {
    final LampDetector d = LampDetector(const LampConfig());
    expect(() {
      for (int i = 0; i < 30; i++) {
        d.addCalibrationFrame(_frame(white: i.isEven ? 0.0 : 0.5));
      }
    }, throwsA(isA<CalibrationException>()));
    expect(d.isCalibrated, isFalse);
  });

  test('слабо горящая красная в нейтральной зоне не «впитывается» в baseline', () {
    final LampDetector d = _calibrated();
    final double before = d.baseline!.red.redFrac;
    // score 0.8: выше OFF (0.6), ниже ON (1.0) — раньше baseline полз вверх.
    for (int i = 0; i < 600; i++) {
      d.evaluate(_frame(red: 0.04));
    }
    expect(d.baseline!.red.redFrac, closeTo(before, 1e-12));
  });

  test('белая погасла, пока горит красная: автомат это не теряет', () {
    final LampDetector d = _calibrated();
    final HitStateMachine m = HitStateMachine(sessionId: 's');
    for (int i = 0; i < 5; i++) {
      m.onEvaluation(d.evaluate(_frame(white: 0.4)));
    }
    for (int i = 0; i < 5; i++) {
      m.onEvaluation(d.evaluate(_frame(white: 0.4, red: 0.10)));
    }
    for (int i = 0; i < 6; i++) {
      m.onEvaluation(d.evaluate(_frame(red: 0.10)));
    }
    expect(m.state, LampSessionState.redOn);
    for (int i = 0; i < 6; i++) {
      m.onEvaluation(d.evaluate(_frame()));
    }
    expect(m.state, LampSessionState.idle);
  });
}
