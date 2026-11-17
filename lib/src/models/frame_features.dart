/// Признаки одной ROI, вычисленные по подвыборке пикселей одного кадра.
class FrameFeatures {
  const FrameFeatures({
    required this.meanY,
    required this.brightFrac,
    required this.sat,
    required this.redDom,
    required this.coreEdgeDiff,
    required this.sampleCount,
    this.whiteFrac = 0,
    this.redFrac = 0,
  });

  /// Пустой набор — используется как заглушка до калибровки.
  static const FrameFeatures zero = FrameFeatures(
    meanY: 0,
    brightFrac: 0,
    sat: 0,
    redDom: 0,
    coreEdgeDiff: 0,
    sampleCount: 0,
  );

  /// Средняя яркость 0..255.
  final double meanY;

  /// Доля пикселей с Y >= LampConfig.brightY, 0..1.
  final double brightFrac;

  /// Средняя насыщенность (max(R,G,B) - min(R,G,B)) / max(R,G,B), 0..1.
  final double sat;

  /// mean(R) - mean((G+B)/2), диапазон примерно -255..255.
  final double redDom;

  /// meanY центральной четверти ROI минус meanY внешнего кольца.
  final double coreEdgeDiff;

  /// Сколько пикселей реально попало в подвыборку.
  final int sampleCount;

  /// Доля пикселей ROI, у которых ВСЕ три канала яркие (min(R,G,B) ≥
  /// whiteMinChannel): «настоящий белый». Не зависит от среднего по ROI.
  final double whiteFrac;

  /// Доля пикселей ROI, где красный заметно выше и зелёного, и синего
  /// (R − max(G,B) ≥ redMargin при R ≥ redMinValue): «настоящий красный».
  final double redFrac;

  @override
  String toString() =>
      'Features(wf=${whiteFrac.toStringAsFixed(3)}, rf=${redFrac.toStringAsFixed(3)}, Y=${meanY.toStringAsFixed(1)}, bright=${brightFrac.toStringAsFixed(3)}, '
      'sat=${sat.toStringAsFixed(3)}, redDom=${redDom.toStringAsFixed(1)}, '
      'coreEdge=${coreEdgeDiff.toStringAsFixed(1)}, n=$sampleCount)';
}

/// Признаки обеих ламп одного кадра.
class LampFrame {
  const LampFrame({
    required this.timestamp,
    required this.white,
    required this.red,
    this.exposureTimeNs,
    this.sensorSensitivity,
  });

  /// Время кадра. Из плагина `camera` 0.12 метка кадра не доступна, поэтому
  /// это время прихода кадра в image stream (см. README, известные ограничения).
  final DateTime timestamp;

  final FrameFeatures white;
  final FrameFeatures red;

  /// Экспозиция сенсора из кадра (наносекунды), если платформа отдала.
  /// Нужна для диагностики дрейфа автоэкспозиции.
  final int? exposureTimeNs;

  final double? sensorSensitivity;
}

/// Калибровка «обе лампы выключены»: средние признаки каждой ROI.
class LampBaseline {
  const LampBaseline({
    required this.white,
    required this.red,
    required this.frameCount,
    this.whiteNoise = 0,
    this.redNoise = 0,
    this.capturedAtMs,
  });

  final FrameFeatures white;
  final FrameFeatures red;

  /// Сколько кадров усреднено (0 = калибровки нет).
  final int frameCount;

  /// Сигма (стандартное отклонение) доли белых пикселей в фоне, измеренная
  /// при калибровке. Нужна, чтобы порог ON не был ниже уровня шума.
  final double whiteNoise;

  /// Сигма доли красных пикселей в фоне.
  final double redNoise;

  /// Метка времени калибровки (мс с эпохи). Нужна, чтобы не грузить
  /// устаревший baseline при другом освещении.
  final int? capturedAtMs;

  bool get isCalibrated => frameCount > 0;

  /// Скользящее обновление среднего фона с сохранением σ и возраста.
  LampBaseline copyWithFeatures({
    required FrameFeatures white,
    required FrameFeatures red,
  }) => LampBaseline(
    white: white,
    red: red,
    frameCount: frameCount,
    whiteNoise: whiteNoise,
    redNoise: redNoise,
    capturedAtMs: capturedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'frame_count': frameCount,
    'white_noise': whiteNoise,
    'red_noise': redNoise,
    'captured_at_ms': capturedAtMs,
    'white': <String, double>{
      'meanY': white.meanY,
      'brightFrac': white.brightFrac,
      'sat': white.sat,
      'redDom': white.redDom,
      'coreEdgeDiff': white.coreEdgeDiff,
      'whiteFrac': white.whiteFrac,
      'redFrac': white.redFrac,
    },
    'red': <String, double>{
      'meanY': red.meanY,
      'brightFrac': red.brightFrac,
      'sat': red.sat,
      'redDom': red.redDom,
      'coreEdgeDiff': red.coreEdgeDiff,
      'whiteFrac': red.whiteFrac,
      'redFrac': red.redFrac,
    },
  };

  factory LampBaseline.fromJson(Map<String, Object?> json) {
    FrameFeatures read(Object? raw) {
      final Map<String, dynamic> m = (raw! as Map).cast<String, dynamic>();
      double value(String key) => (m[key]! as num).toDouble();
      double optional(String key) => (m[key] as num?)?.toDouble() ?? 0;
      return FrameFeatures(
        meanY: value('meanY'),
        brightFrac: value('brightFrac'),
        sat: value('sat'),
        redDom: value('redDom'),
        coreEdgeDiff: value('coreEdgeDiff'),
        sampleCount: 0,
        whiteFrac: optional('whiteFrac'),
        redFrac: optional('redFrac'),
      );
    }

    return LampBaseline(
      white: read(json['white']),
      red: read(json['red']),
      frameCount: (json['frame_count']! as num).toInt(),
      whiteNoise: (json['white_noise'] as num?)?.toDouble() ?? 0,
      redNoise: (json['red_noise'] as num?)?.toDouble() ?? 0,
      capturedAtMs: (json['captured_at_ms'] as num?)?.toInt(),
    );
  }

  @override
  String toString() => 'LampBaseline(frames=$frameCount, white=$white, red=$red)';
}
