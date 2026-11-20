/// Признаки одной ROI, вычисленные по подвыборке пикселей одного кадра.
///
/// Полей ровно столько, сколько нужно: два рабочих (`whiteFrac`, `redFrac`),
/// один контрольный (`sampleCount`) и признаки яркости (`meanY`, `p90Luma`,
/// `lumaStdDev`, `clippedRatio`). Наследие v1 — `brightFrac`, `sat`, `redDom`,
/// `coreEdgeDiff` — удалено: на решение они не влияли, а `sat` и сравнение
/// ядра с кольцом стоили деления и ветки на каждый опрошенный пиксель.
class FrameFeatures {
  const FrameFeatures({
    required this.meanY,
    required this.sampleCount,
    this.whiteFrac = 0,
    this.redFrac = 0,
    this.p90Luma = 0,
    this.lumaStdDev = 0,
    this.clippedRatio = 0,
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

  @override
  String toString() =>
      'Features(wf=${whiteFrac.toStringAsFixed(3)}, rf=${redFrac.toStringAsFixed(3)}, '
      'Y=${meanY.toStringAsFixed(1)}, p90=${p90Luma.toStringAsFixed(1)}, '
      'sd=${lumaStdDev.toStringAsFixed(1)}, clip=${clippedRatio.toStringAsFixed(3)}, '
      'n=$sampleCount)';
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
  };

  static Map<String, Object?> _stateToJson(
    FrameFeatures mean,
    FrameFeatures sigma,
  ) => <String, Object?>{
    'meanY': mean.meanY,
    'whiteFrac': mean.whiteFrac,
    'redFrac': mean.redFrac,
    'p90Luma': mean.p90Luma,
    'lumaStdDev': mean.lumaStdDev,
    'clippedRatio': mean.clippedRatio,
    'meanY_sigma': sigma.meanY,
    'whiteFrac_sigma': sigma.whiteFrac,
    'redFrac_sigma': sigma.redFrac,
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
      frameCount: (raw['frame_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Шесть признаков одного блока состояния. `suffix` — `_sigma` для σ.
  static FrameFeatures _features(Map<dynamic, dynamic> m, String suffix) =>
      FrameFeatures(
        meanY: (m['meanY$suffix'] as num?)?.toDouble() ?? 0,
        sampleCount: 0,
        whiteFrac: (m['whiteFrac$suffix'] as num?)?.toDouble() ?? 0,
        redFrac: (m['redFrac$suffix'] as num?)?.toDouble() ?? 0,
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
      '${redSigma.redFrac.toStringAsFixed(4)})';
}

/// Калибровка в три состояния: фон, горящая белая, горящая красная.
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
  static const int currentVersion = 3;

  final int version;

  /// Обе лампы погашены — от него считается изменение кадра.
  final CalibrationState background;

  /// Держится зажжённой белая лампа.
  final CalibrationState whiteOn;

  /// Держится зажжённой красная лампа.
  final CalibrationState redOn;

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

  /// Калибровка считается готовой только когда набраны все три состояния:
  /// двух не хватает, чтобы разложить изменение на две лампы.
  bool get isCalibrated =>
      version == currentVersion &&
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
      capturedAtMs: (json['captured_at_ms'] as num?)?.toInt() ?? 0,
      exposureTimeNs: (json['exposure_ns'] as num?)?.toInt(),
      sensorSensitivity: (json['sensitivity'] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      'LampBaseline(v$version, bg=${background.frameCount}, '
      'whiteOn=${whiteOn.frameCount}, redOn=${redOn.frameCount}, '
      'exp=${exposureTimeNs ?? '?'}/${sensorSensitivity?.toStringAsFixed(0) ?? '?'})';
}
