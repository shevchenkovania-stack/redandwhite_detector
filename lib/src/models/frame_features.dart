import 'dart:typed_data';

import 'feature_profile.dart';

/// Признаки одной ROI, вычисленные по подвыборке пикселей одного кадра.
///
/// С v6 здесь два набора. Первый — прежние рабочие доли (`whiteFrac`,
/// `redFrac`, `coolFrac`, `warmFrac`) и контроль качества кадра (`meanY`,
/// `p90Luma`, `lumaStdDev`, `clippedRatio`, `sampleCount`). Второй — то, чего в
/// v5 не было и что требует спецификация v6 §2: медианы V и S, доля и геометрия
/// яркого ядра, связные bright-области, «центр поверхности vs остальная ROI» и
/// распределение оттенка. Решение по одному максимальному пикселю здесь не
/// вычисляется нигде.
class FrameFeatures {
  const FrameFeatures({
    required this.meanY,
    required this.sampleCount,
    this.whiteFrac = 0,
    this.redFrac = 0,
    this.coolFrac = 0,
    this.warmFrac = 0,
    this.p90Luma = 0,
    this.lumaStdDev = 0,
    this.clippedRatio = 0,
    this.medianV = 0,
    this.medianS = 0,
    this.brightFrac = 0,
    this.coreAreaFrac = 0,
    this.coreIntensity = 0,
    this.coreRegions = 0,
    this.coreCenterFrac = 0,
    this.centerContrast = 0,
    this.hueHist,
  });

  /// Пустой набор — используется как заглушка до калибровки.
  static const FrameFeatures zero = FrameFeatures(meanY: 0, sampleCount: 0);

  /// Средняя яркость BT.601, 0..255. В score не участвует ни для одной лампы:
  /// красный весит в яркости 0.299, поэтому красная вспышка почти не двигает
  /// `meanY`, а белая поднимает её по всему кадру и ложно триггерит красную
  /// камеру (проверено живьём: 5 белых / 2 красных вместо 6 / 5).
  /// Нужна только чтобы увидеть, что вся сцена посветлела, т.е. автоэкспозиция
  /// уехала и baseline больше не описывает фон.
  final double meanY;

  /// Сколько пикселей реально попало в подвыборку.
  final int sampleCount;

  /// Доля пикселей ROI, у которых ВСЕ три канала яркие (min(R,G,B) ≥
  /// whiteMinChannel): «настоящий белый». Не зависит от среднего по ROI.
  final double whiteFrac;

  /// Доля пикселей ROI, где красный заметно выше и зелёного, и синего
  /// (R − max(G,B) ≥ redMargin при R ≥ redMinValue): «настоящий красный».
  final double redFrac;

  /// Доля пикселей ROI, которые в HSV выглядят «белым светом»: ярко
  /// ([LampConfig.hsvCoolValueMin]) и почти без оттенка
  /// ([LampConfig.hsvCoolSatMax]). Это рабочий признак белой лампы в HSV-счёте.
  ///
  /// Отличие от [whiteFrac] принципиальное: `whiteFrac` порождает абсолютное
  /// число каналов, поэтому при уехавшей автоэкспозиции «белым» становится
  /// полсцены, а `coolFrac` смотрит на ОТТЕНОК — белая лампа при любой
  /// выдержке остаётся обесцвеченной. Замер по 11 видео стенда 23.11.2026: на
  /// 46 включениях, которые модель нашла сама, подъём этой доли 0.061…1.0
  /// (`tools/hsv_stats.py`), а насыщенность ярких пикселей зоны стоит на p50
  /// 0.000…0.35 (`tools/hsv_bounds.py`).
  final double coolFrac;

  /// Доля пикселей ROI «красного света» в HSV: оттенок в окне
  /// [LampConfig.hsvWarmHueMax] градусов вокруг нуля, насыщенность не ниже
  /// [LampConfig.hsvWarmSatMin], яркость не ниже [LampConfig.hsvWarmValueMin].
  /// Рабочий признак красной лампы.
  ///
  /// Окно оттенка шире «чистого красного», потому что лампа на стенде светит
  /// оранжевым: медиана оттенка ядра красной зоны на посчитанных включениях
  /// 25.6…34.7°, p95 33.6…39.8° (`tools/hsv_bounds.py`). При окне 18° признак
  /// почти пуст — 0…70 пикселей на кадр против 128…1716 при 45°, — так что
  /// узкое «красное» окно просто не видело бы лампы. Нижняя граница яркости
  /// отсекает тёмные тёплые пиксели фона — по оттенку они совпадают с лампой.
  final double warmFrac;

  /// Верхний процентиль яркости области ([LampConfig.lumaPercentile], по
  /// умолчанию p90), 0..255. В отличие от максимума одного пикселя не является
  /// бликом: показывает, насколько яркая ВЕРХНЯЯ часть колпака. В паре с
  /// [meanY] это и есть пространственная картина — «мало ярко» против «много
  /// средне».
  final double p90Luma;

  /// Разброс яркости внутри области (СКО, 0..255). Ровная подсветка зала даёт
  /// малое число, локальная вспышка — большое: свет лампы ложится пятном, а
  /// общее освещение поднимает область целиком.
  final double lumaStdDev;

  /// Доля пикселей ярче [LampConfig.clipLuma] — сколько области упёрлось в
  /// потолок сенсора. Признак качества кадра: при большом значении ни цвета,
  /// ни запаса яркости там уже нет, и решение по этой области ненадёжно.
  final double clippedRatio;

  /// Медиана V (максимум каналов, 0..255) по области. v6 §2 требует медиану, а
  /// не среднее и не максимум: медиана стоит на том же месте, когда половина
  /// колпака залита бликом, и не падает, когда половина ушла в тень.
  final double medianV;

  /// Медиана S (0..255 в шкале OpenCV, `S = 255·(mx−mn)/mx`) по области. По ней
  /// видно, что свет стал цветным, даже когда доля «цветных пикселей» ещё мала:
  /// засветка соседней лампы поднимает медиану слабее, чем своё включение.
  final double medianS;

  /// Доля пикселей ярче [LampConfig.v6BrightValueMin] — «bright pixel ratio»
  /// v6 §2. Отличается от [coolFrac]/[warmFrac] тем, что цвета не спрашивает:
  /// это сколько области стало светлой вообще.
  final double brightFrac;

  /// Доля пикселей ярче [LampConfig.v6CoreValueMin] — площадь яркого ядра
  /// источника. У настоящей лампы ядро есть всегда, у равномерной засветки от
  /// соседней — нет: свет ложится плоским пятном без пика.
  final double coreAreaFrac;

  /// Средняя V среди пикселей ядра (0..255), 0 если ядра нет — «bright core
  /// intensity» v6 §2. Ядро может быть маленьким и очень ярким (лампа вблизи)
  /// или широким и тусклым (засветка), и эти два случая надо различать.
  final double coreIntensity;

  /// Сколько отдельных связных яркостей (4-связность по сетке подвыборки) в
  /// области — «connected bright regions» v6 §2. Одна лампа даёт одно ядро; два
  /// и больше — это блик на колпаке плюс отражение, либо чужая лампа в рамке.
  final double coreRegions;

  /// Какая часть пикселей ядра лежит в центральном окне ROI (сторона
  /// [LampConfig.v6CenterSpan] от стороны рамки). Включение лампы бьёт из центра
  /// светящейся поверхности, reflection же ложится по краю и по фону — поэтому
  /// малое число здесь означает «кадр не похож на включение этой лампы».
  final double coreCenterFrac;

  /// Разность средней V центра и средней V остальной области, в долях 0..1
  /// (может быть отрицательной). Это «spatial brightness distribution across
  /// ROI»: локальная вспышка даёт положительный пик, общее освещение зала —
  /// число около нуля, потому что поднимается и центр, и всё вокруг него.
  final double centerContrast;

  /// Распределение оттенка по насыщенным пикселям: [LampConfig.hueBins] корзин
  /// по 360/N градусов, доли 0..1, сумма ≈ 1 (null, если насыщенных пикселей не
  /// было). Нужна именно корзинами, а не средним: красный в HSV стоит на обоих
  /// концах шкалы (0° и 360°), и среднее по такому распределению равно зелёному.
  final Float64List? hueHist;

  /// Доля насыщенных пикселей с оттенком около нуля — красное v6 §4. Красный в
  /// шкале оттенка занимает корзину 0 и последнюю, поэтому суммируются именно
  /// они: среднее по такому распределению показало бы зелёный.
  double get hueRedFrac {
    final Float64List? h = hueHist;
    if (h == null || h.isEmpty) {
      return 0;
    }
    return h[0] + h[h.length - 1];
  }

  /// Вектор признаков в каноническом порядке [V6Feature]: ровно то, что
  /// ложится в профиль калибровки и с чем сравнивается кадр.
  Float64List toVector() {
    final Float64List v = Float64List(V6Feature.count);
    for (int i = 0; i < V6Feature.count; i++) {
      v[i] = V6Feature.values[i].of(this);
    }
    return v;
  }

  @override
  String toString() =>
      'Features(wf=${whiteFrac.toStringAsFixed(3)}, rf=${redFrac.toStringAsFixed(3)}, '
      'cf=${coolFrac.toStringAsFixed(3)}, wr=${warmFrac.toStringAsFixed(3)}, '
      'Y=${meanY.toStringAsFixed(1)}, p90=${p90Luma.toStringAsFixed(1)}, '
      'sd=${lumaStdDev.toStringAsFixed(1)}, clip=${clippedRatio.toStringAsFixed(3)}, '
      'mv=${medianV.toStringAsFixed(0)}, ms=${medianS.toStringAsFixed(0)}, '
      'bf=${brightFrac.toStringAsFixed(3)}, core=${coreAreaFrac.toStringAsFixed(3)}/'
      '${coreIntensity.toStringAsFixed(0)}/n${coreRegions.toStringAsFixed(0)}, '
      'ctr=${coreCenterFrac.toStringAsFixed(2)}/${centerContrast.toStringAsFixed(3)}, '
      'n=$sampleCount)';
}

/// Канонический порядок признаков вектора v6: одно место, где перечислено, ЧЕМ
/// описывается область.
///
/// Профили калибровки, расстояние до профиля, уверенность и колонки CSV строятся
/// по этому списку, поэтому признак, которого здесь нет, в решении участвовать
/// не может — и молча не забудется: число признаков профиля проверяется по
/// [V6Feature.count].
enum V6Feature {
  /// Медиана V (0..255).
  medianV,

  /// Медиана S (0..255).
  medianS,

  /// Доля пикселей «почти без оттенка и ярко» (белый свет).
  coolFrac,

  /// Доля пикселей «тёплый оттенок, насыщенно, ярко» (красный свет).
  warmFrac,

  /// Доля ярких пикселей любого цвета.
  brightFrac,

  /// Площадь яркого ядра.
  coreAreaFrac,

  /// Интенсивность яркого ядра.
  coreIntensity,

  /// Число связных bright-областей.
  coreRegions,

  /// Доля ядра в центре поверхности.
  coreCenterFrac,

  /// Центр против остальной ROI по яркости.
  centerContrast,

  /// Доля насыщенного света с оттенком около нуля — «красного».
  ///
  /// В вектор берётся именно это число, а не вся гистограмма: профиль обязан
  /// хранить по одному распределению на признак, и распределение оттенка
  /// уже лежит внутри [FrameFeatures.hueHist] как отдельный измеренный факт.
  /// Среднее по шкале оттенка здесь не при чём и быть не может: красный стоит
  /// на обоих концах шкалы.
  hueRedFrac,

  /// Верхний процентиль яркости.
  p90Luma,

  /// Разброс яркости.
  lumaStdDev,

  /// Доля пересвеченных пикселей.
  clippedRatio,

  /// Средняя яркость.
  meanY;

  static const int count = 15;

  /// Значение этого признака в кадре.
  double of(FrameFeatures f) => switch (this) {
    V6Feature.medianV => f.medianV,
    V6Feature.medianS => f.medianS,
    V6Feature.coolFrac => f.coolFrac,
    V6Feature.warmFrac => f.warmFrac,
    V6Feature.brightFrac => f.brightFrac,
    V6Feature.coreAreaFrac => f.coreAreaFrac,
    V6Feature.coreIntensity => f.coreIntensity,
    V6Feature.coreRegions => f.coreRegions,
    V6Feature.coreCenterFrac => f.coreCenterFrac,
    V6Feature.centerContrast => f.centerContrast,
    V6Feature.hueRedFrac => f.hueRedFrac,
    V6Feature.p90Luma => f.p90Luma,
    V6Feature.lumaStdDev => f.lumaStdDev,
    V6Feature.clippedRatio => f.clippedRatio,
    V6Feature.meanY => f.meanY,
  };

  /// Имя для логов, отчётов и колонок CSV — одно и то же число везде называется
  /// одинаково.
  String get label => name;
}

/// Признаки обеих ламп одного кадра.
class LampFrame {
  const LampFrame({
    required this.timestamp,
    required this.white,
    required this.red,
    this.whiteRing,
    this.redRing,
    this.exposureTimeNs,
    this.sensorSensitivity,
  });

  /// Время кадра. Из плагина `camera` 0.12 метка кадра не доступна, поэтому
  /// это время прихода кадра в image stream (см. README, известные ограничения).
  final DateTime timestamp;

  final FrameFeatures white;
  final FrameFeatures red;

  /// Признаки кольца вокруг рамки (ореол лампы). Null, если кольцо выключено
  /// ([LampConfig.ringScale] = 1) или режим живого отсчёта не используется.
  /// Нужны потому, что у настоящих ламп светит именно ореол, а колпак при
  /// включении может даже побледнеть.
  final FrameFeatures? whiteRing;
  final FrameFeatures? redRing;

  /// Экспозиция сенсора из кадра (наносекунды), если платформа отдала.
  /// Нужна для диагностики дрейфа автоэкспозиции.
  final int? exposureTimeNs;

  final double? sensorSensitivity;
}

/// Одно состояние калибровки: среднее признаков обеих рамок, их σ и число
/// кадров.
///
/// Состояний при калибровке набирается три: `bg` (обе лампы погашены),
/// `whiteOn` (держится белая) и `redOn` (держится красная). Разность двух
/// состояний — это и есть измеренный отклик лампы, поэтому σ нужна по каждому
/// признаку, а не только по «рабочему»: решение принимается по вектору.
///
/// [whiteProfile] и [redProfile] — то, чего в v5 не было: вместо одного
/// среднего по состоянию там лежит РАСПРЕДЕЛЕНИЕ каждого признака (v6 §8).
/// Среднее и σ остаются, потому что по ним калибровка отбраковывает шумный шаг
/// и считает отклик; профиль же нужен решению, которому мало «стало светлее»,
/// ему нужно «стало похоже на включение этой лампы».
///
/// Кольца (`whiteRing`, `redRing`) — четвёртая и шестая измеряемые области
/// пространственной модели: без них калибровка описывает только два колпака и
/// отличить вспышку своей лампы от засветки чужой может лишь по цвету. Null,
/// когда кольцо не измерялось (ringScale = 1 либо прежняя калибровка).
class CalibrationState {
  const CalibrationState({
    required this.white,
    required this.red,
    required this.whiteSigma,
    required this.redSigma,
    required this.frameCount,
    this.whiteRing,
    this.redRing,
    this.whiteRingSigma,
    this.redRingSigma,
    this.whiteProfile = FeatureProfile.empty,
    this.redProfile = FeatureProfile.empty,
  });

  /// Пустое состояние — шаг калибровки ещё не набран.
  static const CalibrationState empty = CalibrationState(
    white: FrameFeatures.zero,
    red: FrameFeatures.zero,
    whiteSigma: FrameFeatures.zero,
    redSigma: FrameFeatures.zero,
    frameCount: 0,
  );

  /// Среднее по белой рамке и по красной рамке.
  final FrameFeatures white;
  final FrameFeatures red;

  /// Среднее по кольцу (ореолу) каждой рамки; null, если кольцо не мерилось.
  final FrameFeatures? whiteRing;
  final FrameFeatures? redRing;

  /// σ тех же признаков от кадра к кадру внутри этого состояния. Уровень шума
  /// фона (`bg`) — единственная величина, с которой сравнивается отклик.
  final FrameFeatures whiteSigma;
  final FrameFeatures redSigma;

  /// σ признаков колец — нужны тому же вектору, что и средние.
  final FrameFeatures? whiteRingSigma;
  final FrameFeatures? redRingSigma;

  /// Распределения признаков каждой рамки по кадрам этого состояния (v6 §8).
  /// Empty — состояние снято сборкой, которая профили не писала; это не
  /// «признаки не менялись», и решение по профилям обязано это различать.
  final FeatureProfile whiteProfile;
  final FeatureProfile redProfile;

  /// Сколько кадров усреднено (0 = состояние не набрано).
  final int frameCount;

  bool get isEmpty => frameCount == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'frame_count': frameCount,
    'white': _stateToJson(white, whiteSigma),
    'red': _stateToJson(red, redSigma),
    if (whiteRing != null)
      'white_ring': _stateToJson(
        whiteRing!,
        whiteRingSigma ?? FrameFeatures.zero,
      ),
    if (redRing != null)
      'red_ring': _stateToJson(redRing!, redRingSigma ?? FrameFeatures.zero),
    // Профили пишутся только когда они реально набраны: пустой блок в старой
    // записи означал бы «состояние измерено нулём кадров», а его-то как раз и
    // нельзя отличить от «профилей нет».
    if (!whiteProfile.isEmpty) 'white_profile': whiteProfile.toJson(),
    if (!redProfile.isEmpty) 'red_profile': redProfile.toJson(),
  };

  static Map<String, Object?> _stateToJson(
    FrameFeatures mean,
    FrameFeatures sigma,
  ) => <String, Object?>{
    'meanY': mean.meanY,
    'whiteFrac': mean.whiteFrac,
    'redFrac': mean.redFrac,
    // HSV-доли пишутся рядом, но версию не поднимают: решение по эталонам их
    // не читает, а старая запись без них — это «не измерялись», что для
    // эталонного режима верно.
    'coolFrac': mean.coolFrac,
    'warmFrac': mean.warmFrac,
    'p90Luma': mean.p90Luma,
    'lumaStdDev': mean.lumaStdDev,
    'clippedRatio': mean.clippedRatio,
    'meanY_sigma': sigma.meanY,
    'whiteFrac_sigma': sigma.whiteFrac,
    'redFrac_sigma': sigma.redFrac,
    'coolFrac_sigma': sigma.coolFrac,
    'warmFrac_sigma': sigma.warmFrac,
    'p90Luma_sigma': sigma.p90Luma,
    'lumaStdDev_sigma': sigma.lumaStdDev,
    'clippedRatio_sigma': sigma.clippedRatio,
  };

  static CalibrationState fromJson(Object? raw) {
    if (raw is! Map) {
      return CalibrationState.empty;
    }
    FrameFeatures readMean(Map<dynamic, dynamic> m) => _features(m, '');
    FrameFeatures readSigma(Map<dynamic, dynamic> m) => _features(m, '_sigma');
    // Кольца в прежней записи отсутствуют: честный ответ — null, а не ноль,
    // иначе вектор решал бы, что область измерена и стоит на полной темноте.
    Map<dynamic, dynamic>? block(String key) {
      final Object? v = raw[key];
      return v is Map && v.isNotEmpty ? v : null;
    }

    final Map<dynamic, dynamic>? wRing = block('white_ring');
    final Map<dynamic, dynamic>? rRing = block('red_ring');
    final Map<dynamic, dynamic> w =
        (raw['white'] as Map?) ?? const <dynamic, dynamic>{};
    final Map<dynamic, dynamic> r =
        (raw['red'] as Map?) ?? const <dynamic, dynamic>{};
    return CalibrationState(
      white: readMean(w),
      red: readMean(r),
      whiteSigma: readSigma(w),
      redSigma: readSigma(r),
      whiteRing: wRing == null ? null : readMean(wRing),
      redRing: rRing == null ? null : readMean(rRing),
      whiteRingSigma: wRing == null ? null : readSigma(wRing),
      redRingSigma: rRing == null ? null : readSigma(rRing),
      whiteProfile: FeatureProfile.fromJson(raw['white_profile']),
      redProfile: FeatureProfile.fromJson(raw['red_profile']),
      frameCount: (raw['frame_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Признаки одного блока состояния. `suffix` — `_sigma` для σ.
  static FrameFeatures _features(Map<dynamic, dynamic> m, String suffix) =>
      FrameFeatures(
        meanY: (m['meanY$suffix'] as num?)?.toDouble() ?? 0,
        sampleCount: 0,
        whiteFrac: (m['whiteFrac$suffix'] as num?)?.toDouble() ?? 0,
        redFrac: (m['redFrac$suffix'] as num?)?.toDouble() ?? 0,
        coolFrac: (m['coolFrac$suffix'] as num?)?.toDouble() ?? 0,
        warmFrac: (m['warmFrac$suffix'] as num?)?.toDouble() ?? 0,
        p90Luma: (m['p90Luma$suffix'] as num?)?.toDouble() ?? 0,
        lumaStdDev: (m['lumaStdDev$suffix'] as num?)?.toDouble() ?? 0,
        clippedRatio: (m['clippedRatio$suffix'] as num?)?.toDouble() ?? 0,
      );

  @override
  String toString() =>
      'CalibrationState(n=$frameCount, white=$white, red=$red, '
      'σ white=${whiteSigma.whiteFrac.toStringAsFixed(4)}/'
      '${whiteSigma.redFrac.toStringAsFixed(4)}, '
      'σ red=${redSigma.whiteFrac.toStringAsFixed(4)}/'
      '${redSigma.redFrac.toStringAsFixed(4)}, '
      'prof=${whiteProfile.frameCount}/${redProfile.frameCount})';
}

/// Калибровка в три состояния: фон, горящая белая, горящая красная — и
/// опциональное четвёртое (обе лампы горят).
///
/// Прежде состояние было одно («обе выключены»), и отличить одну лампу от
/// другой было нечем, кроме цвета пикселя, — поэтому пересвеченная красная
/// лампа попадала в белую корзину. Теперь носитель решения — форма изменения
/// обеих рамок относительно фона (см. `LampResponseModel`), а цвет остался
/// только способом посчитать признаки.
class LampBaseline {
  const LampBaseline({
    required this.background,
    required this.whiteOn,
    required this.redOn,
    required this.capturedAtMs,
    this.version = currentVersion,
    this.bothOn,
    this.exposureTimeNs,
    this.sensorSensitivity,
  });

  /// Версия формата. Записи без версии — это калибровка в одно состояние, она
  /// физически не содержит эталонов, поэтому при загрузке отвергается.
  ///
  /// v3 — состояния с кольцами и яркостными признаками (p90, разброс, пересвет).
  /// Прежняя v2 содержит только доли цветных пикселей двух ядер, из неё
  /// пространственный вектор не собрать даже частично: молча додумывать ноль
  /// вместо измеренного ореола значит решить, что кольцо всегда было тёмным.
  /// v4 — состояния с профилями распределений (v6 §8). Профиль — не новый
  /// обязательный блок данных, а то, что стало возможно записать: кадры шага
  /// уже лежали в памяти целиком.
  ///
  /// [minSupportedVersion] остаётся 3, и это не экономия на строгости, а
  /// измеренная цена: калибровка v3 содержит три состояния и все ряды, по
  /// которым работает нынешнее решение, а профилей в ней нет. Отвергнуть её —
  /// значит заставить стенд перекалиброваться из-за числа, которое решение ещё
  /// не спросило. Вместо этого `LampProfiles.canDecide` честно отвечает «чем
  /// сравнивать нет», и счёт идёт проверенным путём.
  static const int currentVersion = 4;
  static const int minSupportedVersion = 3;

  final int version;

  /// Обе лампы погашены — от него считается изменение кадра.
  final CalibrationState background;

  /// Держится зажжённой белая лампа.
  final CalibrationState whiteOn;

  /// Держится зажжённой красная лампа.
  final CalibrationState redOn;

  /// Держатся зажжёнными ОБЕ лампы — шаг 4 спецификации v6 §7, опциональный.
  /// Null означает «шаг не снимался», и это законно: simultaneous activation
  /// на стенде может быть невозможно. Пустое состояние вместо null сюда
  /// попадать не должно — решение по профилям читает отсутствие как отсутствие,
  /// а не как «обе лампы горят по нулям».
  final CalibrationState? bothOn;

  /// Метка времени последнего завершённого шага (мс с эпохи). Нужна, чтобы не
  /// грузить устаревшую калибровку при другом освещении.
  final int capturedAtMs;

  /// Свет, при котором набраны состояния: выдержка сенсора (нс) и
  /// чувствительность. Это не признак кадра, а УСЛОВИЕ, при котором все
  /// признаки снимались: на другой выдержке те же числа означают другое
  /// количество света, поэтому эталон с одной экспозицией к другой не
  /// применяется. Null — метку не отдали (платформа, симулятор или калибровка,
  /// снятая до появления поля); сравнивать не с чем, и сброс по экспозиции
  /// просто молчит.
  final int? exposureTimeNs;
  final double? sensorSensitivity;

  /// Калибровка считается готовой только когда набраны все три обязательных
  /// состояния: двух не хватает, чтобы разложить изменение на две лампы.
  /// Четвёртое (обе горят) в список обязательных не входит специально.
  bool get isCalibrated =>
      version >= minSupportedVersion &&
      version <= currentVersion &&
      !background.isEmpty &&
      !whiteOn.isEmpty &&
      !redOn.isEmpty;

  /// Сколько кадров ушло на шаг фона — это число показывали экраны и раньше.
  int get frameCount => background.frameCount;

  /// σ доли белых пикселей в фоне (белая рамка) — для старых сообщений и UI.
  double get whiteNoise => background.whiteSigma.whiteFrac;

  /// σ доли красных пикселей в фоне (красная рамка).
  double get redNoise => background.redSigma.redFrac;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'captured_at_ms': capturedAtMs,
    'exposure_ns': exposureTimeNs,
    'sensitivity': sensorSensitivity,
    'background': background.toJson(),
    'white_on': whiteOn.toJson(),
    'red_on': redOn.toJson(),
    if (bothOn != null) 'both_on': bothOn!.toJson(),
  };

  /// Старый формат (без `version`) читается как «не калибровано»: совместимости
  /// нет, одно переподключение калибровки после смены модели — осознанная цена.
  factory LampBaseline.fromJson(Map<String, Object?> json) {
    final int version = (json['version'] as num?)?.toInt() ?? 1;
    return LampBaseline(
      version: version,
      background: CalibrationState.fromJson(json['background']),
      whiteOn: CalibrationState.fromJson(json['white_on']),
      redOn: CalibrationState.fromJson(json['red_on']),
      bothOn: json['both_on'] == null
          ? null
          : CalibrationState.fromJson(json['both_on']),
      capturedAtMs: (json['captured_at_ms'] as num?)?.toInt() ?? 0,
      exposureTimeNs: (json['exposure_ns'] as num?)?.toInt(),
      sensorSensitivity: (json['sensitivity'] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      'LampBaseline(v$version, bg=${background.frameCount}, '
      'whiteOn=${whiteOn.frameCount}, redOn=${redOn.frameCount}, '
      'bothOn=${bothOn?.frameCount ?? '-'}, '
      'exp=${exposureTimeNs ?? '?'}/${sensorSensitivity?.toStringAsFixed(0) ?? '?'})';
}
