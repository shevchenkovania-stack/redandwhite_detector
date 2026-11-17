/// Все настраиваемые числа детектора в одном месте.
///
/// В логике извлечения признаков, оценки и автомата не должно быть ни одного
/// «магического числа» — только ссылки на этот класс.
class LampConfig {
  const LampConfig({
    this.brightY = 190,
    this.whiteSatMax = 0.25,
    this.whiteOnThreshold = 0.15,
    this.redOnThreshold = 1.0,
    this.redDeltaDivisor = 30,
    this.offRatio = 0.6,
    this.onConfirmFrames = 2,
    this.offConfirmFrames = 3,
    this.baselineAlpha = 0.01,
    this.calibrationFrames = LampConfig.defaultCalibrationFrames,
    this.subsampleStep = 2,
    this.coreSideRatio = 0.5,
    this.analysisIsolateThresholdMs = 8,
    this.yuvFullRange = true,
    this.scoreHistoryPoints = 240,
    this.csvFlushLines = 30,
    this.whiteMinChannel = 170,
    this.redMargin = 60,
    this.redMinValue = 110,
    this.redFracDivisor = 0.05,
    this.noiseSigmas = 6,
    this.calibrationMaxNoise = 0.03,
    this.baselineMaxAgeMinutes = 180,
  });

  /// Порог «яркий пиксель» для [FrameFeatures.brightFrac], 0..255.
  final double brightY;

  /// Максимальная насыщенность, при которой ROI ещё может считаться белой.
  /// Выше — белая лампа не набирает score (это подсветка от красной).
  final double whiteSatMax;

  /// ON-порог белой: whiteScore >= значения brightFrac.
  final double whiteOnThreshold;

  /// ON-порог красной: redScore.
  final double redOnThreshold;

  /// На сколько единиц красноты `redDom` соответствует 1.0 в redScore.
  final double redDeltaDivisor;

  /// OFF-порог = это число от ON-порога (гистерезис).
  final double offRatio;

  /// Подряд кадров выше ON-порога, чтобы подтвердить включение.
  final int onConfirmFrames;

  /// Подряд кадров ниже OFF-порога, чтобы подтвердить выключение.
  final int offConfirmFrames;

  /// Alpha скользящего среднего baseline (обновляется только когда обе лампы OFF).
  final double baselineAlpha;

  /// Сколько кадров берётся для калибровки «обе выключены».
  final int calibrationFrames;

  /// Значение [calibrationFrames] по умолчанию — нужно UI для состояния
  /// калибровки до создания конфига.
  static const int defaultCalibrationFrames = 30;

  /// Шаг подвыборки пикселей: каждый N-й по x и по y.
  final int subsampleStep;

  /// Доля стороны ROI, занимаемая ядром. 0.5 => ядро = 1/4 площади ROI.
  final double coreSideRatio;

  /// Среднее время анализа кадра выше этого значения => выносить в изолят.
  final double analysisIsolateThresholdMs;

  /// True: Y канал YUV420 считается full range (0..255). False: studio range
  /// 16..235 растягивается в 0..255. Зависит от устройства.
  final bool yuvFullRange;

  /// Сколько точек score хранить для графика в демо.
  final int scoreHistoryPoints;

  /// Сколько строк CSV буферизовать перед записью на диск.
  final int csvFlushLines;

  /// Пиксель «настоящий белый», если min(R,G,B) ≥ этого значения (0..255).
  final double whiteMinChannel;

  /// Пиксель «красный», если R − max(G,B) ≥ этого значения…
  final double redMargin;

  /// …и R ≥ этого значения (отсекает тёмно-бордовые тени).
  final double redMinValue;

  /// redScore = (redFrac − фон) / redFracDivisor. 0.05 = лампа должна занять
  /// ≥ 5 % пикселей ROI, чтобы score дошёл до 1.0 (порог ON по умолчанию).
  final double redFracDivisor;

  /// Порог ON не может быть ниже noiseSigmas × σ фона из калибровки.
  final double noiseSigmas;

  /// Калибровка отвергается, если σ whiteFrac/redFrac за её кадры выше этого
  /// (в кадре что-то мигало или двигалось: baseline был бы мусорным).
  final double calibrationMaxNoise;

  /// Калибровка старше этого возраста при запуске не загружается.
  final int baselineMaxAgeMinutes;

  double get whiteOffThreshold => whiteOnThreshold * offRatio;
  double get redOffThreshold => redOnThreshold * offRatio;

  LampConfig copyWith({
    double? brightY,
    double? whiteSatMax,
    double? whiteOnThreshold,
    double? redOnThreshold,
    int? onConfirmFrames,
    int? offConfirmFrames,
    int? calibrationFrames,
    int? subsampleStep,
    bool? yuvFullRange,
  }) => LampConfig(
    brightY: brightY ?? this.brightY,
    whiteSatMax: whiteSatMax ?? this.whiteSatMax,
    whiteOnThreshold: whiteOnThreshold ?? this.whiteOnThreshold,
    redOnThreshold: redOnThreshold ?? this.redOnThreshold,
    redDeltaDivisor: redDeltaDivisor,
    offRatio: offRatio,
    onConfirmFrames: onConfirmFrames ?? this.onConfirmFrames,
    offConfirmFrames: offConfirmFrames ?? this.offConfirmFrames,
    baselineAlpha: baselineAlpha,
    calibrationFrames: calibrationFrames ?? this.calibrationFrames,
    subsampleStep: subsampleStep ?? this.subsampleStep,
    coreSideRatio: coreSideRatio,
    analysisIsolateThresholdMs: analysisIsolateThresholdMs,
    yuvFullRange: yuvFullRange ?? this.yuvFullRange,
    scoreHistoryPoints: scoreHistoryPoints,
    csvFlushLines: csvFlushLines,
    whiteMinChannel: whiteMinChannel,
    redMargin: redMargin,
    redMinValue: redMinValue,
    redFracDivisor: redFracDivisor,
    noiseSigmas: noiseSigmas,
    calibrationMaxNoise: calibrationMaxNoise,
    baselineMaxAgeMinutes: baselineMaxAgeMinutes,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'brightY': brightY,
    'whiteSatMax': whiteSatMax,
    'whiteOnThreshold': whiteOnThreshold,
    'redOnThreshold': redOnThreshold,
    'redDeltaDivisor': redDeltaDivisor,
    'offRatio': offRatio,
    'onConfirmFrames': onConfirmFrames,
    'offConfirmFrames': offConfirmFrames,
    'baselineAlpha': baselineAlpha,
    'calibrationFrames': calibrationFrames,
    'subsampleStep': subsampleStep,
    'coreSideRatio': coreSideRatio,
    'analysisIsolateThresholdMs': analysisIsolateThresholdMs,
    'yuvFullRange': yuvFullRange,
    'scoreHistoryPoints': scoreHistoryPoints,
    'csvFlushLines': csvFlushLines,
    'whiteMinChannel': whiteMinChannel,
    'redMargin': redMargin,
    'redMinValue': redMinValue,
    'redFracDivisor': redFracDivisor,
    'noiseSigmas': noiseSigmas,
    'calibrationMaxNoise': calibrationMaxNoise,
    'baselineMaxAgeMinutes': baselineMaxAgeMinutes,
  };

  factory LampConfig.fromJson(Map<String, Object?> json) {
    const LampConfig def = LampConfig();
    double d(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    int i(String key, int fallback) => (json[key] as num?)?.toInt() ?? fallback;
    bool b(String key, bool fallback) => json[key] as bool? ?? fallback;

    return LampConfig(
      brightY: d('brightY', def.brightY),
      whiteSatMax: d('whiteSatMax', def.whiteSatMax),
      whiteOnThreshold: d('whiteOnThreshold', def.whiteOnThreshold),
      redOnThreshold: d('redOnThreshold', def.redOnThreshold),
      redDeltaDivisor: d('redDeltaDivisor', def.redDeltaDivisor),
      offRatio: d('offRatio', def.offRatio),
      onConfirmFrames: i('onConfirmFrames', def.onConfirmFrames),
      offConfirmFrames: i('offConfirmFrames', def.offConfirmFrames),
      baselineAlpha: d('baselineAlpha', def.baselineAlpha),
      calibrationFrames: i('calibrationFrames', def.calibrationFrames),
      subsampleStep: i('subsampleStep', def.subsampleStep),
      coreSideRatio: d('coreSideRatio', def.coreSideRatio),
      analysisIsolateThresholdMs: d('analysisIsolateThresholdMs', def.analysisIsolateThresholdMs),
      yuvFullRange: b('yuvFullRange', def.yuvFullRange),
      scoreHistoryPoints: i('scoreHistoryPoints', def.scoreHistoryPoints),
      csvFlushLines: i('csvFlushLines', def.csvFlushLines),
      whiteMinChannel: d('whiteMinChannel', def.whiteMinChannel),
      redMargin: d('redMargin', def.redMargin),
      redMinValue: d('redMinValue', def.redMinValue),
      redFracDivisor: d('redFracDivisor', def.redFracDivisor),
      noiseSigmas: d('noiseSigmas', def.noiseSigmas),
      calibrationMaxNoise: d('calibrationMaxNoise', def.calibrationMaxNoise),
      baselineMaxAgeMinutes: i('baselineMaxAgeMinutes', def.baselineMaxAgeMinutes),
    );
  }
}
