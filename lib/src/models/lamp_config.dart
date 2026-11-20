/// Все настраиваемые числа детектора в одном месте.
///
/// В логике извлечения признаков, оценки и автомата не должно быть ни одного
/// «магического числа» — только ссылки на этот класс.
///
/// Чисел специально мало. Пороги `whiteOnThreshold`/`redOnThreshold`,
/// `redFracDivisor` и `noiseSigmas` удалены: решение больше не принимается
/// «по доле пикселей относительно выдуманного порога», оно сравнивается с
/// откликом, который лампа показала на калибровке (см. [hitFraction]), а шум
/// фона берётся из измеренной σ. Настраивать нужно только два числа.
class LampConfig {
  const LampConfig({
    this.hitFraction = 0.6,
    this.templateMinSeparation = 6,
    this.offRatio = 0.6,
    this.onConfirmFrames = 2,
    this.offConfirmFrames = 3,
    this.offConfirmMs = 400,
    this.calibrationFrames = LampConfig.defaultCalibrationFrames,
    this.calibrationMaxNoise = 0.03,
    this.calibrationNoiseRatio = 0.35,
    this.baselineMaxAgeMinutes = 180,
    this.subsampleStep = 2,
    this.analysisIsolateThresholdMs = 8,
    this.yuvFullRange = true,
    this.scoreHistoryPoints = 240,
    this.csvFlushLines = 30,
    this.whiteMinChannel = 170,
    this.redMargin = 60,
    this.redMinValue = 110,
    this.liveReference = true,
    this.referenceWindowFrames = 20,
    this.referencePercentile = 0.2,
    this.referenceNoiseSigmas = 6,
    this.referenceMinRise = 0.03,
    this.referenceMaxLevel = 0.15,
    this.ringScale = 1.7,
    this.lumaPercentile = 0.9,
    this.clipLuma = 248,
  });

  /// Доля измеренного отклика, при которой лампа считается включённой.
  /// Амплитуда `1.0` = «рамка изменилась ровно так, как на калибровке, когда
  /// эту лампу держали зажжённой». `0.6` выбрано, чтобы затекание чужой лампы
  /// (на живых замерах — доли отклика) не проходило, а удар той же лампы по
  /// той же яркости проходил с запасом.
  final double hitFraction;

  /// Во сколько раз измеренный отклик лампы должен превышать шум фона,
  /// иначе калибровка отвергается. Это самопроверка: «немой» канал, рамка не
  /// на том колпаке и лампа, которая мигала во время своего шага, дают
  /// отклик того же порядка, что шум, и калибровка не проходит.
  final double templateMinSeparation;

  /// OFF-порог = это число от ON-порога (гистерезис).
  final double offRatio;

  /// Подряд кадров выше ON-порога, чтобы подтвердить включение.
  final int onConfirmFrames;

  /// Подряд кадров ниже OFF-порога, чтобы подтвердить выключение. Это только
  /// нижняя граница числа кадров: физическую длительность правила задаёт
  /// [offConfirmMs], потому что кадры теряются (`_busy`), и три кадра — это и
  /// 100 мс при 30 к/с, и 250 мс при 12 к/с.
  final int offConfirmFrames;

  /// Как ДОЛГО (мс) обязан держаться провал ниже OFF-уровня, чтобы выключение
  /// считалось подтверждённым по длительности (второе, независимое от глубины
  /// условие).
  ///
  /// Правило в одних кадрах здесь бессильно: кадры теряются (`_busy`), и три
  /// кадра — это и 100 мс при 30 к/с, и 300 мс при 10 к/с. Одна физическая
  /// вспышка идёт волной, и внутри горения амплитуда проваливается (замер
  /// 20.11.2026: провал длиной ровно в 3 обработанных кадра при интервале кадра
  /// 24–100 мс, то есть до ~300 мс) — прежнее правило взводилось заново и
  /// считало один удар дважды.
  ///
  /// Гашение подтверждается, если провал либо ушёл к «полу»
  /// ([referenceMinRise]) — тогда лампу просто не видно, и никакая длительность
  /// не нужна, — либо тянется не короче этого числа. 400 мс — не придуманное
  /// число, а промежуток между двумя измеренными: сверху — потолок
  /// внутриударного провала (~300 мс), снизу — кратчайшая пауза между двумя
  /// настоящими ударами (600 мс у тестовой панели на «Быстро»; по спецификации
  /// 18.11.2026 лампа вообще горит, пока её рукой не выключат, то есть реальный
  /// зазор больше). Правило, которого не хватает на провал и которое не съедает
  /// паузу, может лежать только между ними.
  ///
  /// `0` выключает временное условие: остаётся только проверка глубины.
  /// Достать эти два числа из записи умеет `RunAnalyzer`: он измеряет по CSV
  /// длительности провалов и пауз (`DarkRunTiming`).
  final int offConfirmMs;

  /// Сколько пикселей берётся для КАЖДОГО шага калибровки (фон, белая, красная).
  final int calibrationFrames;

  /// Значение [calibrationFrames] по умолчанию — нужно UI для состояния
  /// калибровки до создания конфига.
  static const int defaultCalibrationFrames = 30;

  /// Калибровка шага отвергается, если устойчивая к выбросам σ его кадров выше
  /// этого (в кадре что-то мигало или двигалось: состояние было бы мусорным).
  /// Это допуск шага «фон» — на шагах горящей лампы к нему добавляется
  /// [calibrationNoiseRatio] от измеренного отклика, потому что мигающая лампа
  /// и есть сигнал, а не помеха.
  final double calibrationMaxNoise;

  /// Долю измеренного отклика, которую разрешено занимать шуму на шаге
  /// «лампа горит». Допуск по признаку `j` =
  /// `max(calibrationMaxNoise, это × |значение − фон|)`: при 0.35 мигающая
  /// лампа вправе шуметь на треть собственного отклика (сетевой LED, рука на
  /// выключателе), а признаки, которые вообще не сдвинулись, по-прежнему
  /// держатся строгого порога фона. Без этой добавки калибровка отвергала ровно
  /// те кадры, ради которых собиралась (замер: σ whiteFrac = 0.158 при отклике
  /// 0.65 — лампа мигает в пределах нормы, а шаг «не прошёл»).
  final double calibrationNoiseRatio;

  /// Калибровка старше этого возраста при запуске не загружается.
  final int baselineMaxAgeMinutes;

  /// Шаг подвыборки пикселей: каждый N-й по x и по y.
  final int subsampleStep;

  /// Среднее время анализа кадра выше этого значения => выносить в изолят.
  final double analysisIsolateThresholdMs;

  /// True: Y канал YUV420 считается full range (0..255). False: studio range
  /// 16..235 растягивается в 0..255. Зависит от устройства.
  final bool yuvFullRange;

  /// Сколько точек графика хранить в демо.
  final int scoreHistoryPoints;

  /// Сколько строк CSV буферизовать перед записью на диск.
  final int csvFlushLines;

  /// Пиксель «настоящий белый», если min(R,G,B) ≥ этого значения (0..255).
  ///
  /// Все три цветовых числа измеряются и пишутся в CSV для разбора записей, но
  /// НИ НА ОДНО РЕШЕНИЕ они не влияют: «белый» и «красный» пиксель выбираются
  /// здесь, а какая лампа сработала — решает яркость четырёх областей и то,
  /// куда она легла. Раньше цвет решал, и из-за этого пересвеченная красная
  /// лампа (для сенсора белая) уезжала в белую корзину.
  final double whiteMinChannel;

  /// Пиксель «красный», если R − max(G,B) ≥ этого значения…
  final double redMargin;

  /// …и R ≥ этого значения (отсекает тёмно-бордовые тени).
  final double redMinValue;

  /// Считать вспышку относительно ЖИВОГО отсчёта, а не относительно
  /// сохранённой калибровки.
  ///
  /// Калибровка описывает одну сцену: сменили набор картинок или окно — и
  /// записанный «ноль» уже не тот, что в кадре. Тогда канал либо прилипает к
  /// «горит», либо замолкает. Живой отсчёт берёт «ноль» из последних кадров,
  /// поэтому работает на любой сцене и переживает смену освещения без
  /// перекалибровки. Калибровка остаётся самопроверкой («рамка видит лампу»).
  final bool liveReference;

  /// Глубина окна живого отсчёта в кадрах (~2 с при 10 к/с).
  final int referenceWindowFrames;

  /// Какой процентиль окна считать «полом» (0.2 = 20-й). Процентиль, а не
  /// среднее: вспышка внутри окна сдвинула бы среднее и вычла себя.
  final double referencePercentile;

  /// Во сколько σ окна должен подняться признак, чтобы это была вспышка.
  final double referenceNoiseSigmas;

  /// Абсолютный минимум подъёма: на идеально ровной сцене шум равен нулю, и
  /// порог «6σ» не защищает от единичных пикселей.
  final double referenceMinRise;

  /// Потолок порога ON и одновременно признак того, что живой отсчёт больше
  /// ничего не измеряет.
  ///
  /// Нужен потому, что подъём над «полом» физически ограничен единицей, а `6σ`
  /// потолка не имеет: камера погуляла по сцене — и порог стал 1.2–1.5, до
  /// которого вспышке не достать НИКОГДА (замер 20.11.2026: `onW 1.256`,
  /// `onR 1.521` при подъёме 0.561 — канал молчал до самого перезапуска).
  /// Упереться в потолок значит «окно описывает не темноту, а движение», и
  /// тогда окно набирается заново вместо того, чтобы вечно не досчитывать.
  ///
  /// 0.15 — между измеренным шумом закреплённой камеры (6σ ≈ 0.03–0.12) и
  /// минимальным измеренным подъёмом настоящей лампы (0.12–0.56).
  final double referenceMaxLevel;

  /// Во сколько раз расширять рамку для кольца-ореола. У настоящих ламп
  /// сигнал живёт в ореоле: колпак при включении может даже побледнеть
  /// (пересвет), а растёт именно кольцо. 1.0 — кольцо не считается.
  final double ringScale;

  /// Какой процентиль яркости брать по области (0.9 = p90, 0.95 = p95).
  /// Процентиль, а не максимум: один яркий пиксель — это блик, пылинка или
  /// шум квантования, а верх распределения показывает, какая площадь колпака
  /// реально засвечена.
  final double lumaPercentile;

  /// Яркость пикселя (0..255), с которой он считается пересвеченным: выше
  /// него сенсор стоит на потолке, и запаса яркости там уже нет. Доля таких
  /// пикселей — признак качества кадра, а не признак лампы.
  final double clipLuma;

  /// Копия с одним-двумя изменёнными числами. Менять настройку стенда имеет
  /// смысл по одному фактору за раз, иначе непонятно, что именно улучшило или
  /// сломало результат. Перечислять здесь обязано все поля: молча сброшенное
  /// число было бы тем самым «одновременным изменением двух факторов».
  LampConfig copyWith({
    double? hitFraction,
    double? templateMinSeparation,
    double? offRatio,
    int? onConfirmFrames,
    int? offConfirmFrames,
    int? offConfirmMs,
    int? calibrationFrames,
    double? calibrationMaxNoise,
    double? calibrationNoiseRatio,
    int? baselineMaxAgeMinutes,
    int? subsampleStep,
    double? analysisIsolateThresholdMs,
    bool? yuvFullRange,
    int? scoreHistoryPoints,
    int? csvFlushLines,
    double? whiteMinChannel,
    double? redMargin,
    double? redMinValue,
    bool? liveReference,
    int? referenceWindowFrames,
    double? referencePercentile,
    double? referenceNoiseSigmas,
    double? referenceMinRise,
    double? referenceMaxLevel,
    double? ringScale,
    double? lumaPercentile,
    double? clipLuma,
  }) {
    return LampConfig(
      hitFraction: hitFraction ?? this.hitFraction,
      templateMinSeparation: templateMinSeparation ?? this.templateMinSeparation,
      offRatio: offRatio ?? this.offRatio,
      onConfirmFrames: onConfirmFrames ?? this.onConfirmFrames,
      offConfirmFrames: offConfirmFrames ?? this.offConfirmFrames,
      offConfirmMs: offConfirmMs ?? this.offConfirmMs,
      calibrationFrames: calibrationFrames ?? this.calibrationFrames,
      calibrationMaxNoise: calibrationMaxNoise ?? this.calibrationMaxNoise,
      calibrationNoiseRatio: calibrationNoiseRatio ?? this.calibrationNoiseRatio,
      baselineMaxAgeMinutes: baselineMaxAgeMinutes ?? this.baselineMaxAgeMinutes,
      subsampleStep: subsampleStep ?? this.subsampleStep,
      analysisIsolateThresholdMs:
          analysisIsolateThresholdMs ?? this.analysisIsolateThresholdMs,
      yuvFullRange: yuvFullRange ?? this.yuvFullRange,
      scoreHistoryPoints: scoreHistoryPoints ?? this.scoreHistoryPoints,
      csvFlushLines: csvFlushLines ?? this.csvFlushLines,
      whiteMinChannel: whiteMinChannel ?? this.whiteMinChannel,
      redMargin: redMargin ?? this.redMargin,
      redMinValue: redMinValue ?? this.redMinValue,
      liveReference: liveReference ?? this.liveReference,
      referenceWindowFrames: referenceWindowFrames ?? this.referenceWindowFrames,
      referencePercentile: referencePercentile ?? this.referencePercentile,
      referenceNoiseSigmas: referenceNoiseSigmas ?? this.referenceNoiseSigmas,
      referenceMinRise: referenceMinRise ?? this.referenceMinRise,
      referenceMaxLevel: referenceMaxLevel ?? this.referenceMaxLevel,
      ringScale: ringScale ?? this.ringScale,
      lumaPercentile: lumaPercentile ?? this.lumaPercentile,
      clipLuma: clipLuma ?? this.clipLuma,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'hitFraction': hitFraction,
    'templateMinSeparation': templateMinSeparation,
    'offRatio': offRatio,
    'onConfirmFrames': onConfirmFrames,
    'offConfirmFrames': offConfirmFrames,
    'offConfirmMs': offConfirmMs,
    'calibrationFrames': calibrationFrames,
    'calibrationMaxNoise': calibrationMaxNoise,
    'calibrationNoiseRatio': calibrationNoiseRatio,
    'baselineMaxAgeMinutes': baselineMaxAgeMinutes,
    'subsampleStep': subsampleStep,
    'analysisIsolateThresholdMs': analysisIsolateThresholdMs,
    'yuvFullRange': yuvFullRange,
    'scoreHistoryPoints': scoreHistoryPoints,
    'csvFlushLines': csvFlushLines,
    'whiteMinChannel': whiteMinChannel,
    'redMargin': redMargin,
    'redMinValue': redMinValue,
    'liveReference': liveReference,
    'referenceWindowFrames': referenceWindowFrames,
    'referencePercentile': referencePercentile,
    'referenceNoiseSigmas': referenceNoiseSigmas,
    'referenceMinRise': referenceMinRise,
    'referenceMaxLevel': referenceMaxLevel,
    'ringScale': ringScale,
    'lumaPercentile': lumaPercentile,
    'clipLuma': clipLuma,
  };

  /// Сохранённые конфиги могут содержать уже удалённые ключи (`brightY`,
  /// `whiteSatMax`, `redDeltaDivisor`, `coreSideRatio`, `baselineAlpha`,
  /// `whiteOnThreshold`, `redOnThreshold`, `redFracDivisor`, `noiseSigmas`,
  /// `spatialVectors`) — они игнорируются.
  factory LampConfig.fromJson(Map<String, Object?> json) {
    const LampConfig def = LampConfig();
    double d(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    int i(String key, int fallback) => (json[key] as num?)?.toInt() ?? fallback;
    bool b(String key, bool fallback) => json[key] as bool? ?? fallback;

    return LampConfig(
      hitFraction: d('hitFraction', def.hitFraction),
      templateMinSeparation: d('templateMinSeparation', def.templateMinSeparation),
      offRatio: d('offRatio', def.offRatio),
      onConfirmFrames: i('onConfirmFrames', def.onConfirmFrames),
      offConfirmFrames: i('offConfirmFrames', def.offConfirmFrames),
      offConfirmMs: i('offConfirmMs', def.offConfirmMs),
      calibrationFrames: i('calibrationFrames', def.calibrationFrames),
      calibrationMaxNoise: d('calibrationMaxNoise', def.calibrationMaxNoise),
      calibrationNoiseRatio: d('calibrationNoiseRatio', def.calibrationNoiseRatio),
      baselineMaxAgeMinutes: i('baselineMaxAgeMinutes', def.baselineMaxAgeMinutes),
      subsampleStep: i('subsampleStep', def.subsampleStep),
      analysisIsolateThresholdMs: d('analysisIsolateThresholdMs', def.analysisIsolateThresholdMs),
      yuvFullRange: b('yuvFullRange', def.yuvFullRange),
      scoreHistoryPoints: i('scoreHistoryPoints', def.scoreHistoryPoints),
      csvFlushLines: i('csvFlushLines', def.csvFlushLines),
      whiteMinChannel: d('whiteMinChannel', def.whiteMinChannel),
      redMargin: d('redMargin', def.redMargin),
      redMinValue: d('redMinValue', def.redMinValue),
      liveReference: b('liveReference', def.liveReference),
      referenceWindowFrames: i('referenceWindowFrames', def.referenceWindowFrames),
      referencePercentile: d('referencePercentile', def.referencePercentile),
      referenceNoiseSigmas: d('referenceNoiseSigmas', def.referenceNoiseSigmas),
      referenceMinRise: d('referenceMinRise', def.referenceMinRise),
      referenceMaxLevel: d('referenceMaxLevel', def.referenceMaxLevel),
      ringScale: d('ringScale', def.ringScale),
      lumaPercentile: d('lumaPercentile', def.lumaPercentile),
      clipLuma: d('clipLuma', def.clipLuma),
    );
  }
}
