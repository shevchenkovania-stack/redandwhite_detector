// Детектор в режиме эталонов. Прежде здесь были «формулы score»; сейчас —
// проверки измеренных эталонов.
//
// Решение одно: яркость четырёх измеряемых областей и то, в какую рамку она
// легла. Прежнего цветового способа здесь больше нет — он не переключается и
// не проверяется, потому что пересвеченную красную лампу он клал в белую
// корзину.
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/src/detection/hit_state_machine.dart';
import 'package:lamp_detection/src/detection/lamp_calibration.dart';
import 'package:lamp_detection/src/detection/lamp_detector.dart';
import 'package:lamp_detection/src/models/frame_features.dart';
import 'package:lamp_detection/src/models/hit_event.dart';
import 'package:lamp_detection/src/models/lamp_config.dart';
import 'package:lamp_detection/src/detection/response_model.dart';

/// Тёмный фон измеряемой области: 60 уровней в среднем, 100 на верху
/// распределения, ореол — 40 и 70.
const double _bgMean = 60;
const double _bgP90 = 100;

/// Во сколько раз ореол слабее колпака в тех же единицах яркости.
const double _haloFactor = 0.6;

/// Кадр одной рамки в двух единицах сразу.
///
/// Доля «своих» пикселей и яркость области описывают ОДИН И ТОТ ЖЕ свет,
/// поэтому числа согласованы: свой свет поднимает и долю, и яркость. Доля
/// измеряется и записывается, но решает яркость. `red` в белой рамке — это
/// чужие пиксели: они меняют только цвет.
FrameFeatures _f({double white = 0, double red = 0}) {
  final double own = (white + red).clamp(0.0, 1.0);
  return FrameFeatures(
    meanY: _bgMean + 140 * own,
    p90Luma: _bgP90 + 135 * own,
    sampleCount: 100,
    whiteFrac: white,
    redFrac: red,
  );
}

/// Ореол своей лампы: тот же свет, но расплывшийся — в полтора раза слабее
/// колпака. Кольца здесь обязательны: без них вектор
/// собирается из двух колпаков, и калибровка отвергается как «нет колец».
FrameFeatures _halo(FrameFeatures core) => FrameFeatures(
  meanY: 40 + (core.meanY - _bgMean) * _haloFactor,
  p90Luma: 70 + (core.meanY - _bgMean) * _haloFactor,
  sampleCount: 900,
  whiteFrac: core.whiteFrac * 0.5,
  redFrac: core.redFrac * 0.5,
);

/// Ореол, который потемнел ровно на ту же долю, на которую поднялось ядро.
/// Лампа так не умеет: её свет всегда расплывается за колпак. Это и есть
/// «чужак» — картина, которую ни один эталон не ждёт.
FrameFeatures _inverseHalo(double own) => FrameFeatures(
  meanY: 40 - 140 * _haloFactor * own,
  p90Luma: 70 - 140 * _haloFactor * own,
  sampleCount: 900,
);

DateTime _t = DateTime(2026, 1, 1);
LampFrame _frame({double white = 0, double red = 0}) {
  _t = _t.add(const Duration(milliseconds: 33));
  final FrameFeatures w = _f(white: white);
  final FrameFeatures r = _f(red: red);
  return LampFrame(
    timestamp: _t,
    white: w,
    red: r,
    whiteRing: _halo(w),
    redRing: _halo(r),
  );
}

/// Кормит детектор одним состоянием столько кадров, сколько он ждёт на шаг.
void _state(LampDetector d, LampFrame Function() frame) {
  for (int i = 0; i < d.config.calibrationFrames; i++) {
    d.addCalibrationFrame(frame());
  }
}

/// Полная калибровка: фон нулевой, белая даёт 0.4 в своей рамке, красная —
/// 0.3 в своей. Отдельно от «перетекания» — картины изменения не пересекаются.
///
/// Режим эталонов включён явно: эти тесты проверяют разложение отклика на
/// измеренные эталоны, а не живой отсчёт.
LampDetector _calibrated({
  double whiteOn = 0.4,
  double redOn = 0.3,
  double backgroundWhite = 0,
  double backgroundRed = 0,
}) {
  final LampConfig config = LampConfig(liveReference: false);
  final LampDetector d = LampDetector(config);
  _state(d, () => _frame(white: backgroundWhite, red: backgroundRed));
  _state(d, () => _frame(white: whiteOn, red: backgroundRed));
  _state(d, () => _frame(white: backgroundWhite, red: redOn));
  expect(d.isCalibrated, isTrue);
  return d;
}

void main() {
  group('режим эталонов: решение по яркости четырёх областей', () {
    test('три состояния дают два разных измеряемых эталона', () {
      final LampDetector d = _calibrated();
      final LampResponseModel m = d.model!;
      expect(m.vector.length, LampVector.coordinateCount);
      expect(m.whiteResponse, greaterThan(0));
      expect(m.redResponse, greaterThan(0));
      expect(m.crosstalk, closeTo(0, 1e-12));
      expect(m.isValid, isTrue);

      // Своя лампа изменила СВОИ области и не тронула чужие: ни одного числа,
      // которого в калибровке не измеряли.
      expect(m.whiteTemplate[LampVector.whiteCoreMean], greaterThan(0));
      expect(m.whiteTemplate[LampVector.whiteRingMean], greaterThan(0));
      expect(m.whiteTemplate[LampVector.redCoreMean], closeTo(0, 1e-12));
      expect(m.redTemplate[LampVector.redCoreMean], greaterThan(0));
      expect(m.redTemplate[LampVector.redRingMean], greaterThan(0));
      expect(m.redTemplate[LampVector.whiteCoreMean], closeTo(0, 1e-12));
    });

    test('лампа, которая горела уже на шаге «фон», отвергается с именем шага', () {
      final LampDetector d = LampDetector(LampConfig(liveReference: false));
      // Красная горит всё время: её «отклик относительно фона» равен нулю, и
      // именно это раньше убивало канал молча — детектор считал её фоном.
      expect(
        () {
          _state(d, () => _frame(red: 0.3));
          _state(d, () => _frame(white: 0.4, red: 0.3));
          _state(d, () => _frame(red: 0.3));
        },
        throwsA(
          isA<CalibrationException>().having(
            (CalibrationException e) => e.message,
            'message',
            contains('красная'),
          ),
        ),
      );
      expect(d.isCalibrated, isFalse);
    });

    test('одно включение — ровно одно событие, гашение снимает lit', () {
      final LampDetector d = _calibrated();
      final HitStateMachine m = HitStateMachine(sessionId: 's');
      int hits = 0;
      for (int i = 0; i < 6; i++) {
        hits += m.onEvaluation(d.evaluate(_frame(white: 0.4))).length;
      }
      expect(hits, 1);
      expect(d.evaluate(_frame(white: 0.4)).whiteAmplitude, closeTo(1, 1e-9));
      for (int i = 0; i < 6; i++) {
        m.onEvaluation(d.evaluate(_frame()));
      }
      expect(m.state, LampSessionState.idle);
    });

    test('затекание красной в белую рамку не даёт белого события', () {
      final LampDetector d = _calibrated();
      final HitStateMachine m = HitStateMachine(sessionId: 's');
      int white = 0;
      int red = 0;
      for (int i = 0; i < 6; i++) {
        // Красная лампа подсветила белую рамку: 0.05 из 0.4 её отклика.
        for (final HitEvent e in m.onEvaluation(d.evaluate(_frame(white: 0.05, red: 0.3)))) {
          if (e.color == HitColor.white) {
            white++;
          } else {
            red++;
          }
        }
      }
      expect(red, 1);
      expect(white, 0);
    });

    test('белая погасла, пока красная горит: автомат это не теряет', () {
      final LampDetector d = _calibrated();
      final HitStateMachine m = HitStateMachine(sessionId: 's');
      for (int i = 0; i < 5; i++) {
        m.onEvaluation(d.evaluate(_frame(white: 0.4)));
      }
      for (int i = 0; i < 5; i++) {
        m.onEvaluation(d.evaluate(_frame(white: 0.4, red: 0.3)));
      }
      for (int i = 0; i < 6; i++) {
        m.onEvaluation(d.evaluate(_frame(red: 0.3)));
      }
      expect(m.state, LampSessionState.redOn);
      for (int i = 0; i < 6; i++) {
        m.onEvaluation(d.evaluate(_frame()));
      }
      expect(m.state, LampSessionState.idle);
    });

    test('кадр, не похожий ни на один эталон, не даёт событий вообще', () {
      final LampDetector d = _calibrated();
      final HitStateMachine m = HitStateMachine(sessionId: 's');
      // Чужак: ядро яркое, а ореол вокруг него потемнел — так не умеет ни одна
      // лампа, потому что её свет всегда расплывается.
      final LampFrame raw = LampFrame(
        timestamp: _t.add(const Duration(milliseconds: 33)),
        white: _f(white: 0.4),
        red: _f(),
        whiteRing: _inverseHalo(0.4),
        redRing: _halo(_f()),
      );
      final LampEvaluation foreign = d.evaluate(raw);
      final LampEvaluation e = d.evaluate(_frame());
      expect(foreign.unexplained, isTrue);
      expect(m.onEvaluation(foreign), isEmpty);
      expect(m.onEvaluation(e), isEmpty);
    });

    test('baseline после калибровки не меняется никогда', () {
      final LampDetector d = _calibrated();
      final double before = d.baseline!.background.red.redFrac;
      for (int i = 0; i < 600; i++) {
        d.evaluate(_frame(white: 0.4, red: 0.3));
      }
      expect(d.baseline!.background.red.redFrac, closeTo(before, 1e-12));
      expect(d.baseline!.background.white.whiteFrac, closeTo(0, 1e-12));
    });
  });
}
