// Решение «какая лампа горит» берут яркость ЧЕТЫРЁХ измеряемых областей и то,
// КУДА лёг свет. Доли белых и красных пикселей в этих тестах выставлены нарочно
// враждебно — там, где цвет сказал бы одно, яркость обязана сказать другое.
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' show min;

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/src/detection/hit_state_machine.dart';
import 'package:lamp_detection/src/detection/lamp_calibration.dart';
import 'package:lamp_detection/src/detection/lamp_detector.dart';
import 'package:lamp_detection/src/detection/response_model.dart';
import 'package:lamp_detection/src/models/frame_features.dart';
import 'package:lamp_detection/src/models/hit_event.dart';
import 'package:lamp_detection/src/models/lamp_config.dart';

/// Одна измеряемая область. Процентиль на 10 уровней выше среднего, но никогда
/// не выше 255: пересвеченная область упёрлась в потолок, и p90 там такой же,
/// какой и mean.
FrameFeatures _area(double mean, {double whiteFrac = 0, double redFrac = 0}) => FrameFeatures(
  meanY: mean,
  p90Luma: min(255.0, mean + 10),
  sampleCount: 400,
  whiteFrac: whiteFrac,
  redFrac: redFrac,
);

const double _bgCore = 60;
const double _bgRing = 40;

/// Кадр четырёх областей: ядро и кольцо каждой рамки. `rings: false` — это
/// ringScale = 1, когда ореол вообще не измерялся.
LampFrame _scene({
  double whiteCore = _bgCore,
  double whiteRing = _bgRing,
  double redCore = _bgCore,
  double redRing = _bgRing,
  double whiteWf = 0,
  double whiteRf = 0,
  double redWf = 0,
  double redRf = 0,
  bool rings = true,
}) {
  _clock = _clock.add(const Duration(milliseconds: 33));
  return LampFrame(
    timestamp: _clock,
    white: _area(whiteCore, whiteFrac: whiteWf, redFrac: whiteRf),
    red: _area(redCore, whiteFrac: redWf, redFrac: redRf),
    whiteRing: rings ? _area(whiteRing) : null,
    redRing: rings ? _area(redRing) : null,
  );
}

late DateTime _clock;

/// Обе лампы погашены.
LampFrame _off({bool rings = true}) => _scene(rings: rings);

/// Белая горит: её ядро и ореол вспыхивают, красная остаётся на уровне фона.
LampFrame _whiteLit() => _scene(whiteCore: 200, whiteRing: 120);

/// Красная лампа, залитая до пересвета: сенсор видит в красной рамке БЕЛЫЙ
/// (whiteFrac 0.9, redFrac 0), но свет лёг вокруг КРАСНОЙ рамки. Прежний
/// вектор отдал бы этот кадр белой лампе.
LampFrame _redBlown() => _scene(redCore: 255, redRing: 150, redWf: 0.9);

/// Подъём общего освещения (автоэкспозиция): обе рамки поднялись одинаково.
LampFrame _commonRise() =>
    _scene(whiteCore: _bgCore + 30, whiteRing: _bgRing + 20, redCore: _bgCore + 30, redRing: _bgRing + 20);

/// Белая лампа под цветным фильтром: «белых» пикселей в её рамке почти нет,
/// зато свет лёг вокруг БЕЛОЙ рамки и её ореола. Цвет сказал бы «красная»,
/// геометрия обязана сказать «белая».
LampFrame _whiteTinted() =>
    _scene(whiteCore: 190, whiteRing: 115, whiteWf: 0.05, whiteRf: 0.55);

/// Белая горит и захватила красную рамку: чужая поднялась, но заметно меньше,
/// чем своя вместе со своим ореолом.
LampFrame _whiteSpill() =>
    _scene(whiteCore: 200, whiteRing: 120, redCore: 85, redRing: 52, whiteWf: 0.5);

/// Конфиг режима эталонов: решение по измеренным откликам, набор шага
/// короткий — синтетика шума не имеет.
LampConfig _cfg({bool rings = true, double ringScale = 1.7}) => LampConfig(
  liveReference: false,
  calibrationFrames: 3,
  ringScale: rings ? ringScale : 1,
);

void _state(LampDetector d, LampFrame frame) {
  for (int i = 0; i < d.config.calibrationFrames; i++) {
    d.addCalibrationFrame(frame);
  }
}

/// Полная пространственная калибровка: фон → белая → красная (пересвет).
LampDetector _spatial({LampFrame? whiteOn, LampFrame? redOn, LampConfig? config}) {
  final LampDetector d = LampDetector(config ?? _cfg());
  _state(d, _off());
  _state(d, whiteOn ?? _whiteLit());
  _state(d, redOn ?? _redBlown());
  return d;
}

/// Прогон кадров через детектор и автомат, как живая сессия.
List<HitEvent> _feed(LampDetector d, HitStateMachine m, List<LampFrame> frames) =>
    frames.expand((LampFrame f) => m.onEvaluation(d.evaluate(f))).toList(growable: false);

void main() {
  setUp(() => _clock = DateTime(2026, 1, 1));

  test('пересвеченная красная лампа остаётся красной', () {
    final LampDetector d = _spatial();
    expect(d.isCalibrated, isTrue);
    expect(d.model!.vector.length, LampVector.coordinateCount);
    expect(d.model!.crosstalk, closeTo(0, 1e-12));

    final HitStateMachine m = HitStateMachine(sessionId: 's', idGenerator: () => 'e');
    final List<HitEvent> events = _feed(d, m, [_redBlown(), _redBlown(), _redBlown()]);
    expect(events.map((HitEvent e) => e.lampId).toList(), <String>[HitEvent.redLampId]);
  });

  test('белая лампа с изменённым оттенком остаётся белой', () {
    // Обязательный тест инструкции №2: оттенок пересвеченной или окрашенной
    // лампы не должен уводить событие в чужую корзину.
    final LampDetector d = _spatial();
    final HitStateMachine m = HitStateMachine(sessionId: 's', idGenerator: () => 'e');
    final List<HitEvent> events = _feed(d, m, [_whiteTinted(), _whiteTinted(), _whiteTinted()]);
    expect(events.map((HitEvent e) => e.lampId).toList(), <String>[HitEvent.whiteLampId]);
  });

  test('белая лампа не создаёт ложного события красной', () {
    // Обязательный тест инструкции №4: зеркальный к проверке затекания красной.
    final LampDetector d = _spatial();
    final LampEvaluation e = d.evaluate(_whiteSpill());
    expect(e.whiteAmplitude, greaterThan(d.config.hitFraction));
    expect(e.redAmplitude, lessThan(d.config.hitFraction));

    final HitStateMachine m = HitStateMachine(sessionId: 's', idGenerator: () => 'e');
    final List<HitEvent> events = _feed(d, m, [_whiteSpill(), _whiteSpill(), _whiteSpill()]);
    expect(events.map((HitEvent e) => e.lampId).toList(), <String>[HitEvent.whiteLampId]);
  });

  test('общий подъём света не зажигает ни один канал', () {
    final LampDetector d = _spatial();
    final LampEvaluation e = d.evaluate(_commonRise());
    expect(e.whiteAmplitude, lessThan(d.config.hitFraction));
    expect(e.redAmplitude, lessThan(d.config.hitFraction));

    final HitStateMachine m = HitStateMachine(sessionId: 's', idGenerator: () => 'e');
    expect(_feed(d, m, [_commonRise(), _commonRise(), _commonRise()]), isEmpty);
  });

  test('лампа шага видна без цветных пикселей, а общий свет — нет', () {
    final LampConfig config = _cfg();
    final LampCalibration c = LampCalibration(config);
    for (int i = 0; i < config.calibrationFrames; i++) {
      c.addFrame(_off());
    }
    // Шаг «фон» набран, дальше калибровка ждёт белую, но спросить можно про
    // любую лампу.
    expect(c.lampAppeared(_whiteLit(), CalibrationStep.whiteOn), isTrue);
    expect(c.lampAppeared(_redBlown(), CalibrationStep.redOn), isTrue);
    expect(c.lampAppeared(_commonRise(), CalibrationStep.whiteOn), isFalse);
    expect(c.lampAppeared(_commonRise(), CalibrationStep.redOn), isFalse);
    expect(c.lampAppeared(_off(), CalibrationStep.redOn), isFalse);
  });

  test('одинаковые шаблоны — это проблема геометрии, а не мусорное решение', () {
    // Красная «горит» ровно тем же рисунком, что белая: разделить лампы нечем,
    // и калибровка обязана сказать об этом прямо.
    final LampConfig config = _cfg();
    final LampDetector d = LampDetector(config);
    expect(
      () {
        _state(d, _off());
        _state(d, _whiteLit());
        _state(d, _whiteLit());
      },
      throwsA(
        isA<CalibrationException>().having(
          (CalibrationException e) => e.message,
          'message',
          contains('перетекание'),
        ),
      ),
    );
    expect(d.isCalibrated, isFalse);
  });

  test('пространственная калибровка без измеренных колец не притворяется', () {
    // ringScale = 1: ореолов нет, и восьмимерный вектор молча съехался бы до
    // яркости двух колпаков. Такую калибровку принято отвергать, а не решать.
    final LampConfig config = _cfg(rings: false);
    final LampDetector d = LampDetector(config);
    expect(
      () {
        _state(d, _off(rings: false));
        _state(d, _scene(whiteCore: 200, rings: false));
        _state(d, _scene(redCore: 255, rings: false));
      },
      throwsA(
        isA<CalibrationException>().having(
          (CalibrationException e) => e.message,
          'message',
          contains('ореолы'),
        ),
      ),
    );
  });

  test('состояния переживают запись вместе с кольцами и яркостью', () {
    CalibrationState state(double ringMean) => CalibrationState(
      white: _area(_bgCore),
      red: _area(_bgCore),
      whiteSigma: FrameFeatures.zero,
      redSigma: FrameFeatures.zero,
      whiteRing: _area(ringMean),
      redRing: _area(ringMean),
      whiteRingSigma: FrameFeatures.zero,
      redRingSigma: FrameFeatures.zero,
      frameCount: 3,
    );
    CalibrationState ringless() => CalibrationState(
      white: _area(_bgCore),
      red: _area(_bgCore),
      whiteSigma: FrameFeatures.zero,
      redSigma: FrameFeatures.zero,
      frameCount: 3,
    );
    final LampBaseline baseline = LampBaseline(
      background: state(_bgRing),
      whiteOn: state(120),
      redOn: ringless(),
      capturedAtMs: 1,
    );

    final LampBaseline back = LampBaseline.fromJson(
      jsonDecode(jsonEncode(baseline.toJson())) as Map<String, Object?>,
    );
    expect(back.version, LampBaseline.currentVersion);
    expect(back.isCalibrated, isTrue);
    expect(back.background.whiteRing?.meanY, _bgRing);
    expect(back.whiteOn.redRing?.p90Luma, 130);
    // Состояние, в котором ореол не измерялся, обязан остаться без него: ноль
    // вместо null означал бы «кольцо всегда было чёрным».
    expect(back.redOn.whiteRing, isNull);
    expect(back.redOn.redRing, isNull);
  });

  test('вектор подписывает свои координаты', () {
    const LampVector v = LampVector();
    expect(v.name(LampVector.redRingMean), contains('кольца красной'));
    expect(v.name(LampVector.whiteCoreP90), contains('p90 ядра белой'));
    expect(v.length, 8);
    // Координат ровно восемь: четыре области × два числа яркости, цвета в них
    // нет ни одной.
    expect(LampVector.coordinateCount, 8);
  });
}
