import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Тесты слоя v6: признаки геометрии света → робастные распределения → семь
/// профилей калибровки → решение по профилям (§5, §8, §9) и ровно два режима
/// (§3).
///
/// Калибровка здесь собрана РУКАМИ, а не набрана через `addCalibrationFrame`.
/// Причина не лень: различать обязан ровно один признак в каждой зоне, иначе
/// расстояние профиля — среднее по пятнадцати слагаемым, и ожидаемое число в
/// тесте пришлось бы пересчитывать тем же кодом, который он проверяет. Один
/// признак даёт числа, которые можно вывести на бумаге и сравнить вслепую.
///
/// Числа подобраны под измеренный дефект, ради которого v6 и затеян: красная
/// лампа на пересвете выбивает БЕЛУЮ зону в «белый» подъём, и прежний путь
/// (60 ошибок на разметке заказчика, журнал 46) считает её вспышку белой. Профиль
/// обязан тот же кадр не подтвердить, не отняв ни одного правильного события.
int _ids = 0;
String _nextId() => 'v6-${++_ids}';

/// cool белая зона: фон / своя вспышка / чужая вспышка, залившая эту зону.
const double _wOff = 0.02;
const double _wOn = 0.90;
const double _wSpill = 0.50;

/// warm красная зона: те же три состояния.
const double _rOff = 0.02;
const double _rOn = 0.85;
const double _rSpill = 0.05;

/// Кадр reflection-случая: белая зона поднялась сильно (её и назовёт белой
/// выученное правило), но именно так, как её залила красная лампа.
const double _reflectWhiteCool = 0.56;
const double _reflectRedWarm = 0.30;

FrameFeatures _zone({required double cool, required double warm}) {
  final double v = cool > warm ? cool : warm;
  return FrameFeatures(
    meanY: 255 * v,
    p90Luma: 255 * v,
    sampleCount: 400,
    coolFrac: cool,
    warmFrac: warm,
  );
}

/// σ состояния: маленький, но ненулевой — калибровка с нулевым шумом сама по
/// себе подозрительна, и выученное правило сверяется именно с ней.
final FrameFeatures _sigma = FrameFeatures(
  meanY: 0.002,
  sampleCount: 0,
  coolFrac: 0.002,
  warmFrac: 0.002,
);

/// Профиль, в котором различает ровно один признак: остальные — пустые
/// распределения, и [FeatureProfile.distanceOf] их честно пропускает.
FeatureProfile _profile(V6Feature f, double median, {int frames = 30}) =>
    FeatureProfile(
      distributions: <FeatureDistribution>[
        for (final V6Feature x in V6Feature.values)
          x == f
              ? FeatureDistribution(
                  median: median,
                  p05: median,
                  p25: median,
                  p75: median,
                  p95: median,
                  count: frames,
                )
              : FeatureDistribution.empty,
      ],
      frameCount: frames,
    );

/// Состояние калибровки: средние обеих зон, их σ и профили по одному признаку.
CalibrationState _state({
  required double whiteCool,
  required double redWarm,
  bool profiles = true,
  int frames = 30,
}) => CalibrationState(
  white: _zone(cool: whiteCool, warm: 0.01),
  red: _zone(cool: 0.02, warm: redWarm),
  whiteSigma: _sigma,
  redSigma: _sigma,
  frameCount: frames,
  whiteProfile:
      profiles ? _profile(V6Feature.coolFrac, whiteCool, frames: frames) : FeatureProfile.empty,
  redProfile:
      profiles ? _profile(V6Feature.warmFrac, redWarm, frames: frames) : FeatureProfile.empty,
);

/// Калибровка стенда: фон → белая горит → красная горит (+ необязательное
/// «обе горят»). `profiles: false` — ровно то, что содержит файл v3.
LampBaseline _baseline({bool profiles = true, bool bothOn = false}) => LampBaseline(
  version: profiles ? 4 : 3,
  background: _state(whiteCool: _wOff, redWarm: _rOff, profiles: profiles),
  whiteOn: _state(whiteCool: _wOn, redWarm: _rSpill, profiles: profiles),
  redOn: _state(whiteCool: _wSpill, redWarm: _rOn, profiles: profiles),
  bothOn: bothOn
      ? _state(whiteCool: _wOn, redWarm: _rOn, profiles: profiles)
      : null,
  capturedAtMs: 0,
);

LampConfig _cfg({required bool profiles}) => LampConfig(
  hsvReference: true,
  liveReference: false,
  // Порог 0.20 вместо 0.40: подъём reflection-кадра (0.54) обязан быть выше
  // уровня, иначе проверялся бы отказ профиля, а не кадр, дошедший до решения.
  hsvMaxLevel: 0.20,
  v6ProfileDecision: profiles,
);

/// Прогон кадров через детектор + автомат в режиме HSV с собранной руками
/// калибровкой.
class _Bench {
  _Bench({required bool profiles, LampBaseline? baseline})
    : detector = LampDetector(_cfg(profiles: profiles)) {
    detector.setBaseline(baseline ?? _baseline());
    warmup();
  }

  final LampDetector detector;
  final HitStateMachine machine = HitStateMachine(
    sessionId: 'v6',
    idGenerator: _nextId,
  );
  final List<HitEvent> events = <HitEvent>[];
  LampEvaluation? last;
  int _frame = 0;

  /// Окно «пола» набирается из тёмных кадров: нужно 10 из окна в 20.
  void warmup([int frames = 12]) {
    for (int i = 0; i < frames; i++) {
      feed();
    }
  }

  List<HitEvent> feed({
    double whiteCool = _wOff,
    double redWarm = _rOff,
  }) {
    final int index = _frame++;
    final LampEvaluation e = detector.evaluate(
      LampFrame(
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + index * 100),
        white: _zone(cool: whiteCool, warm: 0.01),
        red: _zone(cool: 0.02, warm: redWarm),
      ),
    );
    last = e;
    final List<HitEvent> produced = machine.onEvaluation(e);
    events.addAll(produced);
    return produced;
  }

  int get whiteHits =>
      events.where((HitEvent e) => e.color == HitColor.white).length;
  int get redHits =>
      events.where((HitEvent e) => e.color == HitColor.red).length;
}

FeatureCsvRow _row(int index, {required double whiteCool, required double redWarm}) =>
    FeatureCsvRow(
      timestampMs: 1000 + index * 100,
      white: _zone(cool: whiteCool, warm: 0.01),
      red: _zone(cool: 0.02, warm: redWarm),
      state: 'working',
    );

/// Запись: темнота → вспышка [whiteCool]/[redWarm] → темнота.
String _csv({
  required double whiteCool,
  required double redWarm,
  int flashFrames = 5,
  int darkFrames = 12,
}) {
  final List<FeatureCsvRow> rows = <FeatureCsvRow>[];
  int i = 0;
  for (; i < darkFrames; i++) {
    rows.add(_row(i, whiteCool: _wOff, redWarm: _rOff));
  }
  for (int k = 0; k < flashFrames; k++, i++) {
    rows.add(_row(i, whiteCool: whiteCool, redWarm: redWarm));
  }
  for (int k = 0; k < darkFrames; k++, i++) {
    rows.add(_row(i, whiteCool: _wOff, redWarm: _rOff));
  }
  return FeatureCsv.encode(rows);
}

void main() {
  group('Вектор признаков v6', () {
    test('вектор несёт ровно 15 признаков в каноническом порядке', () {
      final FrameFeatures f = FrameFeatures(
        meanY: 14,
        sampleCount: 400,
        coolFrac: 2,
        warmFrac: 3,
        p90Luma: 11,
        lumaStdDev: 12,
        clippedRatio: 13,
        medianV: 0,
        medianS: 1,
        brightFrac: 4,
        coreAreaFrac: 5,
        coreIntensity: 6,
        coreRegions: 7,
        coreCenterFrac: 8,
        centerContrast: 9,
      );
      final Float64List v = f.toVector();
      expect(v.length, V6Feature.count);
      expect(V6Feature.count, 15);
      // Каждое место вектора названо: профиль, расстояние и колонки CSV
      // строятся по этому порядку, и перестановка здесь молча переписала бы
      // решение.
      for (final V6Feature feature in V6Feature.values) {
        expect(v[feature.index], feature.of(f), reason: feature.label);
      }
      expect(v[V6Feature.medianV.index], 0);
      expect(v[V6Feature.centerContrast.index], 9);
      expect(v[V6Feature.meanY.index], 14);
    });

    test('красный оттенок считается по обоим концам шкалы', () {
      // Красный в HSV стоит на 0° и на 360°, поэтому суммируются первая и
      // последняя корзина; среднее по такой шкале показало бы зелёный.
      final Float64List hist = Float64List(16);
      hist[0] = 0.2;
      hist[15] = 0.1;
      hist[5] = 0.7;
      expect(
        FrameFeatures(meanY: 0, sampleCount: 0, hueHist: hist).hueRedFrac,
        closeTo(0.3, 1e-12),
      );
      expect(const FrameFeatures(meanY: 0, sampleCount: 0).hueRedFrac, 0,
          reason: 'насыщенных пикселей не было — доли нет, а не ноль-доказательство');
      final Float64List green = Float64List(16)..[5] = 1;
      expect(FrameFeatures(meanY: 0, sampleCount: 0, hueHist: green).hueRedFrac, 0);
    });
  });

  group('Робастные распределения (v6 §8)', () {
    test('медиана и квартили считаются по линейной интерполяции', () {
      final FeatureDistribution d = FeatureDistribution.fromValues(
        <double>[1, 2, 3, 4, 5, 6, 7, 8, 9],
      );
      expect(d.count, 9);
      expect(d.median, 5);
      expect(d.p25, 3);
      expect(d.p75, 7);
      expect(d.p05, closeTo(1.4, 1e-12));
      expect(d.p95, closeTo(8.6, 1e-12));
      expect(d.iqrSigma, closeTo(4 / 1.349, 1e-9));
      expect(FeatureDistribution.fromValues(<double>[]).isEmpty, isTrue);
    });

    test('один сумасшедший кадр не сдвигает середину, как сдвигает min/max', () {
      final FeatureDistribution clean = FeatureDistribution.fromValues(
        <double>[5, 5, 5, 5, 5, 5, 5, 5, 5, 200],
      );
      expect(clean.median, 5, reason: 'рука в кадре не переписывает эталон');
      expect(clean.p95, lessThan(200));
    });

    test('пол разброса привязан к уровню признака, а не к одной константе', () {
      // Вектор смешан по шкалам: medianV в 0..255, coreAreaFrac в 0..1, и
      // глобальный «пол в 0.01» для яркости означал бы «шума нет вообще».
      final FeatureDistribution flat = FeatureDistribution.fromValues(
        <double>[5, 5, 5, 5],
      );
      expect(flat.iqrSigma, 0);
      expect(flat.sigmaOf(0.02), closeTo(0.1, 1e-12));
      expect(flat.notDiscriminating, isFalse);
      final FeatureDistribution zero = FeatureDistribution.fromValues(
        <double>[0, 0, 0, 0],
      );
      expect(zero.notDiscriminating, isTrue, reason: 'ноль медиана и ноль разброс');
      expect(zero.sigmaOf(0.02), 0);
    });
  });

  group('Профиль и расстояние до него', () {
    test('своё состояние ближе, чем чужое', () {
      final List<FrameFeatures> onFrames = <FrameFeatures>[
        _zone(cool: 0.90, warm: 0.01),
        _zone(cool: 0.92, warm: 0.01),
        _zone(cool: 0.88, warm: 0.02),
      ];
      final FeatureProfile on = FeatureProfile.fromFrames(onFrames);
      expect(on.frameCount, 3);
      expect(on.distributions.length, V6Feature.count);
      expect(
        on.distanceOf(_zone(cool: 0.90, warm: 0.01).toVector(), minSigma: 0.02,
            features: V6Feature.values),
        lessThan(
          on.distanceOf(_zone(cool: 0.02, warm: 0.01).toVector(), minSigma: 0.02,
              features: V6Feature.values),
        ),
      );
      expect(on.liveFeatureCount, greaterThan(0));
    });

    test('признак без разбросов в расстояние не входит, а пустой профиль — бесконечность', () {
      const FeatureProfile empty = FeatureProfile.empty;
      expect(
        empty.distance(_zone(cool: 0.5, warm: 0.5).toVector(), minSigma: 0.02),
        double.infinity,
      );
      // Ровная синтетика: все кадры одинаковые и нулевые — профилю нечем ни
      // подтвердить, ни опровергнуть.
      final FeatureProfile dead = FeatureProfile.fromFrames(<FrameFeatures>[
        const FrameFeatures(meanY: 0, sampleCount: 0),
        const FrameFeatures(meanY: 0, sampleCount: 0),
      ]);
      expect(
        dead.distance(_zone(cool: 0.5, warm: 0.5).toVector(), minSigma: 0.02),
        double.infinity,
      );
      expect(dead.liveFeatureCount, 0);
      expect(empty.liveFeatureCount, 0);
    });

    test('профиль переживает JSON, а обрезанный считается отсутствующим', () {
      final FeatureProfile p = _profile(V6Feature.coolFrac, 0.5);
      final FeatureProfile back = FeatureProfile.fromJson(p.toJson());
      expect(back.frameCount, p.frameCount);
      expect(back[V6Feature.coolFrac].median, 0.5);
      expect(back.distributions.length, V6Feature.count);
      // Короткий список — не «некоторые признаки нулевые», а профиль чужой
      // сборки: решение по нему строить нельзя.
      expect(FeatureProfile.fromJson(<Object?>[30, <Object?>[]]).isEmpty, isTrue);
      expect(FeatureProfile.fromJson(null).isEmpty, isTrue);
    });
  });

  group('LampProfiles: семь состояний и spill', () {
    test('spill берётся из ЧУЖОЙ зоны того же состояния', () {
      final LampProfiles p = LampProfiles.from(_baseline());
      expect(p.canDecide, isTrue);
      // WHITE_ROI_RED_SPILL — белая зона в кадре, где держали КРАСНУЮ.
      expect(p.whiteRoiRedSpill[V6Feature.coolFrac].median, _wSpill);
      expect(p.redRoiWhiteSpill[V6Feature.warmFrac].median, _rSpill);
      expect(p.whiteOn[V6Feature.coolFrac].median, _wOn);
      expect(p.whiteOff[V6Feature.coolFrac].median, _wOff);
      expect(p.bothOnWhite, isNull, reason: 'шаг 4 не снимался — это отсутствие, а не ноль');
      expect(p.describe(), contains('spill=30/30'));
    });

    test('калибровка v3 остаётся годной, но решать по профилям нечем', () {
      final LampProfiles p = LampProfiles.from(_baseline(profiles: false));
      expect(p.canDecide, isFalse);
      expect(LampProfiles.none.canDecide, isFalse);
      expect(
        LampBaseline.fromJson(_baseline(profiles: false).toJson()).isCalibrated,
        isTrue,
        reason: 'v3 не отвергается: отвергнуть её — значит заставить стенд '
            'перекалиброваться из-за числа, которое решение ещё не спросило',
      );
    });

    test('шаг 4 необязателен, но когда снят — лежит в модели', () {
      expect(CalibrationStep.mandatory, isNot(contains(CalibrationStep.bothOn)));
      expect(CalibrationStep.bothOn.isOptional, isTrue);
      final LampProfiles p = LampProfiles.from(_baseline(bothOn: true));
      expect(p.canDecide, isTrue);
      expect(p.bothOnWhite?.frameCount, 30);
      expect(p.bothOnRed?.frameCount, 30);
      expect(p.describe(), contains('both=30'));
      final Map<String, Object?> json =
          LampBaseline.fromJson(_baseline(bothOn: true).toJson()).toJson();
      expect(json.containsKey('both_on'), isTrue);
    });
  });

  group('ProfileDecider (§5, §9.7)', () {
    test('кадр как ON: уверенность 1, подозрения нет', () {
      final ProfileVerdict v = _verdictWhite(_wOn);
      expect(v.available, isTrue);
      expect(v.confidence, closeTo(1, 1e-6));
      expect(v.suspicion, lessThan(0.5));
    });

    test('кадр ровно как spill: подозрение 1, уверенность гаснет', () {
      final ProfileVerdict v = _verdictWhite(_wSpill);
      expect(v.suspicion, closeTo(1, 1e-6));
      expect(v.confidence, lessThan(0.35),
          reason: 'на своё включение кадр не похож — этого отказа достаточно');
      expect(v.distanceSpill, closeTo(0, 1e-9));
    });

    test('кадр между ON и spill: отказ именно как отражение', () {
      // Полоса, в которой работает второе правило отказа: уверенность ещё
      // выше v6MinConfidence, но соседняя лампа выглядит убедительнее.
      final ProfileVerdict v = _verdictWhite(_reflectWhiteCool);
      expect(v.confidence, closeTo(0.5776, 1e-3));
      expect(v.suspicion, closeTo(0.7589, 1e-3));
      expect(v.suspicion, greaterThanOrEqualTo(0.65));
      expect(_verdictRed(_reflectRedWarm).confidence, closeTo(0.9560, 1e-3));
    });

    test('без одного из трёх профилей вердикта нет, а не нули', () {
      final ProfileDecider d = ProfileDecider(_cfg(profiles: true));
      final ProfileVerdict v = d.verdict(
        x: _zone(cool: 0.5, warm: 0).toVector(),
        off: _profile(V6Feature.coolFrac, _wOff),
        on: FeatureProfile.empty,
        spill: _profile(V6Feature.coolFrac, _wSpill),
      );
      expect(v, same(ProfileVerdict.unavailable));
      expect(v.available, isFalse);
      expect(v.confidence, 0, reason: 'ноль здесь означает «не измерено»');
    });
  });

  group('Отказ профиля в детекторе (§5)', () {
    test('reflection-кадр: прежний путь считает белую вспышку, профили её снимают', () {
      final _Bench plain = _Bench(profiles: false);
      final _Bench profiled = _Bench(profiles: true);
      for (int i = 0; i < 4; i++) {
        plain.feed(
          whiteCool: _reflectWhiteCool,
          redWarm: _reflectRedWarm,
        );
        profiled.feed(
          whiteCool: _reflectWhiteCool,
          redWarm: _reflectRedWarm,
        );
      }
      // Измеренный путь называет кадр белым — это и есть тот дефект, из-за
      // которого v6 затевалось.
      expect(plain.whiteHits, 1);
      expect(plain.detector.refusedFrames, 0,
          reason: 'с выключенным словом профилей отказ не применяется');
      expect(plain.last!.whiteConfidence, closeTo(0.5776, 1e-3),
          reason: 'числа считаются всегда, когда их чем считать: иначе A/B '
              'требовал бы двух прогонов');

      expect(profiled.whiteHits, 0, reason: 'v6 §5: не подтверждать соседней лампой');
      expect(profiled.redHits, 0);
      expect(profiled.detector.refusedFrames, greaterThan(0));
      expect(profiled.detector.reflectionRefusals, greaterThan(0));
      expect(profiled.detector.unknownFrames, greaterThan(0));
      expect(profiled.last!.unknown, isTrue);
      expect(profiled.last!.unknownReason, contains('отражение'));
    });

    test('своё включение профиль не трогает: событие на месте', () {
      final _Bench b = _Bench(profiles: true);
      for (int i = 0; i < 4; i++) {
        b.feed(whiteCool: _wOn, redWarm: _rSpill);
      }
      expect(b.whiteHits, 1, reason: 'правило приёмки v6 §7: не потерять меренное');
      expect(b.detector.refusedFrames, 0);
      expect(b.detector.unknownFrames, 0);
      expect(b.last!.whiteConfidence, closeTo(1, 1e-6));
      expect(b.last!.unknown, isFalse);
    });

    test('отказ касается только rising edge: горение не дробится', () {
      final _Bench b = _Bench(profiles: true);
      for (int i = 0; i < 3; i++) {
        b.feed(whiteCool: _wOn, redWarm: _rSpill);
      }
      expect(b.whiteHits, 1);
      expect(b.last!.whiteLit, isTrue);
      // Пока канал горит, профили права голоса не имеют: гашение решает
      // измеренный путь, и одного профиля хватило бы, чтобы разорвать горение.
      for (int i = 0; i < 5; i++) {
        b.feed(whiteCool: _reflectWhiteCool, redWarm: _reflectRedWarm);
      }
      expect(b.detector.refusedFrames, 0, reason: 'горящему каналу отказ не выдаётся');
      expect(b.whiteHits, 1);
      for (int i = 0; i < 6; i++) {
        b.feed();
      }
      expect(b.last!.whiteLit, isFalse);
      expect(b.whiteHits, 1, reason: 'гашение — не событие');
    });

    test('калибровка v3: решение остаётся деревом v5, отказов нет', () {
      final _Bench b = _Bench(profiles: true, baseline: _baseline(profiles: false));
      expect(b.detector.profilesDecide, isFalse);
      for (int i = 0; i < 4; i++) {
        b.feed(whiteCool: _reflectWhiteCool, redWarm: _reflectRedWarm);
      }
      expect(b.whiteHits, 1);
      expect(b.detector.refusedFrames, 0);
      expect(b.last!.whiteConfidence, isNull, reason: 'чем считать — нет');
      expect(b.last!.unknown, isFalse);
    });

    test('счётчики отказов обнуляются сбросом трассировки', () {
      final _Bench b = _Bench(profiles: true);
      for (int i = 0; i < 4; i++) {
        b.feed(whiteCool: _reflectWhiteCool, redWarm: _reflectRedWarm);
      }
      expect(b.detector.refusedFrames, greaterThan(0));
      b.detector.resetTracking();
      expect(b.detector.refusedFrames, 0);
      expect(b.detector.reflectionRefusals, 0);
      expect(b.detector.unknownFrames, 0);
    });

    test('отчёт говорит разными словами про три разных случая', () {
      expect(
        LampDetector(_cfg(profiles: true)).profileDecision,
        contains('калибровки нет'),
      );
      expect(
        _Bench(profiles: false).detector.profileDecision,
        contains('решает измеренный HSV-путь'),
      );
      final String decided = _Bench(profiles: true).detector.profileDecision;
      expect(decided, contains('уверенность ≥ 35%'));
      expect(decided, contains('отражение ≥ 65%'));
      expect(LampDetector(const LampConfig(hsvReference: false)).profileDecision, isEmpty,
          reason: 'в прежнем режиме этого вопроса не существует');
    });
  });

  group('Ровно два режима (v6 §3)', () {
    test('hsv и hsvCalibration — одно число v6ProfileDecision', () {
      expect(LampCountMode.hsv.name, 'hsv');
      expect(LampCountMode.hsvCalibration.name, 'hsvCalibration');
      for (final LampCountMode mode in <LampCountMode>[
        LampCountMode.hsv,
        LampCountMode.hsvCalibration,
      ]) {
        final LampConfig c = const LampConfig().withCountMode(mode);
        expect(c.hsvReference, isTrue);
        expect(c.liveReference, isFalse);
        expect(c.countMode, mode, reason: 'режим обязан считываться обратно');
        expect(c.v6ProfileDecision, mode == LampCountMode.hsvCalibration);
      }
    });

    test('прежние режимы читаются из сохранённого конфига', () {
      expect(const LampConfig(liveReference: true, hsvReference: false).countMode,
          LampCountMode.live);
      expect(const LampConfig(liveReference: false, hsvReference: false).countMode,
          LampCountMode.etalon);
      expect(const LampConfig().withCountMode(LampCountMode.etalon).hsvReference, isFalse);
      expect(const LampConfig().withCountMode(LampCountMode.live).liveReference, isTrue);
    });

    test('числа v6 переживают сохранение, признаки читаются по именам', () {
      final LampConfig c = LampConfig(
        v6MinConfidence: 0.42,
        v6ReflectionVeto: 0.7,
        v6ReflectionWeight: 0.5,
        v6CoreFeatures: <V6Feature>[V6Feature.medianV, V6Feature.coreAreaFrac],
        v6ProfileDecision: false,
      );
      final LampConfig back = LampConfig.fromJson(c.toJson());
      expect(back.v6MinConfidence, 0.42);
      expect(back.v6ReflectionVeto, 0.7);
      expect(back.v6ReflectionWeight, 0.5);
      expect(back.v6ProfileDecision, isFalse);
      expect(back.v6CoreFeatures, c.v6CoreFeatures);
      // Имена, а не индексы: порядок enum может измениться.
      expect(
        LampConfig.fromJson(<String, Object?>{
          'v6CoreFeatures': <Object?>['medianV', 'такого-признака-нет'],
        }).v6CoreFeatures,
        <V6Feature>[V6Feature.medianV],
      );
      expect(
        LampConfig.fromJson(<String, Object?>{
          'v6CoreFeatures': <Object?>['нет'],
        }).v6CoreFeatures,
        LampConfig.defaultV6CoreFeatures,
        reason: 'до нуля признаков выключать решение нельзя',
      );
    });
  });

  group('CSV v6 и разбор одной записи', () {
    test('формат v6: 91 колонка, уверенность и подозрение пишутся и читаются', () {
      expect(FeatureCsvRow.header.split(',').length,
          FeatureCsvRow.currentColumnCount);
      expect(FeatureCsvRow.currentColumnCount, 91);
      final FrameFeatures white = FrameFeatures(
        meanY: 255 * _reflectWhiteCool,
        p90Luma: 255 * _reflectWhiteCool,
        sampleCount: 400,
        coolFrac: _reflectWhiteCool,
        warmFrac: 0.01,
        medianV: 200,
      );
      final FeatureCsvRow row = FeatureCsvRow(
        timestampMs: 1000,
        white: white,
        red: _zone(cool: 0.02, warm: _reflectRedWarm),
        state: 'working',
        whiteConfidence: 0.5776,
        redConfidence: 0.956,
        whiteSuspicion: 0.7589,
        redSuspicion: 0.1145,
      );
      final List<String> cells = row.toCsvLine().split(',');
      expect(cells.length, 91);
      final FeatureCsvRow back = FeatureCsvRow.parse(row.toCsvLine());
      expect(back.whiteConfidence, closeTo(0.5776, 1e-5));
      expect(back.redConfidence, closeTo(0.956, 1e-5));
      expect(back.whiteSuspicion, closeTo(0.7589, 1e-5));
      expect(back.redSuspicion, closeTo(0.1145, 1e-5));
      expect(back.white.coolFrac, closeTo(_reflectWhiteCool, 1e-5));
      expect(back.white.medianV, 200);
    });

    test('старая строка не притворяется новой: уверенности нет', () {
      final String v6 = FeatureCsvRow(
        timestampMs: 1000,
        white: _zone(cool: 0.5, warm: 0.01),
        red: _zone(cool: 0.02, warm: 0.4),
        state: 'working',
        whiteConfidence: 0.9,
      ).toCsvLine();
      final String v5 = v6.split(',').take(69).join(',');
      final FeatureCsvRow old = FeatureCsvRow.parse(v5);
      expect(old.whiteConfidence, isNull, reason: 'null — «не считалось», а не «ноль»');
      expect(old.white.coolFrac, closeTo(0.5, 1e-5));
      expect(old.white.medianV, 0);
    });

    test('одна запись, решённая обоими режимами: профили снимают ровно это событие', () {
      final RunAb ab = RunAnalyzer.analyzeBothModes(
        _csv(whiteCool: _reflectWhiteCool, redWarm: _reflectRedWarm),
        base: _cfg(profiles: true),
        baseline: _baseline(),
      );
      expect(ab.plain.whiteEvents, 1);
      expect(ab.profiled.whiteEvents, 0);
      expect(ab.whiteDelta, -1);
      expect(ab.eventDelta, -1);
      expect(ab.plain.mode, 'hsv');
      expect(ab.profiled.mode, 'hsvCalibration');
      expect(ab.plain.refusedFrames, 0);
      expect(ab.profiled.reflectionRefusals, greaterThan(0));
      // Задержка (§14) измеряется в обоих режимах: в профильном подъём был,
      // события нет — это пропуск, и он обязан быть виден числом.
      expect(ab.plain.whiteLatency.measured, isTrue);
      expect(ab.profiled.whiteLatency.misses, greaterThan(0));
      expect(ab.verdict, contains('разница'));
      expect(ab.describe(), contains('hsvCalibration'));
    });

    test('разбор своего включения ничего не теряет', () {
      final RunAb ab = RunAnalyzer.analyzeBothModes(
        _csv(whiteCool: _wOn, redWarm: _rSpill),
        base: _cfg(profiles: true),
        baseline: _baseline(),
      );
      expect(ab.plain.whiteEvents, 1);
      expect(ab.profiled.whiteEvents, 1, reason: 'v6 §7: не хуже измеренного');
      expect(ab.eventDelta, 0);
      expect(ab.profiled.refusedFrames, 0);
      expect(ab.verdict, contains('счёт совпал'));
    });

    test('HSV-разбор без калибровки не запускается вовсе', () {
      expect(
        () => RunAnalyzer.analyze(
          _csv(whiteCool: _wOn, redWarm: _rSpill),
          base: _cfg(profiles: true),
        ),
        throwsArgumentError,
      );
    });
  });
}

/// Вердикт белой зоны по собранной калибровке — один вызов, чтобы арифметика
/// тестов читалась на бумаге.
ProfileVerdict _verdictWhite(double cool) {
  final LampProfiles p = LampProfiles.from(_baseline());
  return ProfileDecider(_cfg(profiles: true)).verdict(
    x: _zone(cool: cool, warm: 0.01).toVector(),
    off: p.whiteOff,
    on: p.whiteOn,
    spill: p.whiteRoiRedSpill,
  );
}

ProfileVerdict _verdictRed(double warm) {
  final LampProfiles p = LampProfiles.from(_baseline());
  return ProfileDecider(_cfg(profiles: true)).verdict(
    x: _zone(cool: 0.02, warm: warm).toVector(),
    off: p.redOff,
    on: p.redOn,
    spill: p.redRoiWhiteSpill,
  );
}
