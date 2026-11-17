/// Признаки одной ROI, вычисленные по подвыборке пикселей одного кадра.
class FrameFeatures {
  const FrameFeatures({
    required this.meanY,
    required this.brightFrac,
    required this.sat,
    required this.redDom,
    required this.coreEdgeDiff,
    required this.sampleCount,
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

  @override
  String toString() =>
      'Features(Y=${meanY.toStringAsFixed(1)}, bright=${brightFrac.toStringAsFixed(3)}, '
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
  });

  final FrameFeatures white;
  final FrameFeatures red;

  /// Сколько кадров усреднено (0 = калибровки нет).
  final int frameCount;

  bool get isCalibrated => frameCount > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'frame_count': frameCount,
    'white': <String, double>{
      'meanY': white.meanY,
      'brightFrac': white.brightFrac,
      'sat': white.sat,
      'redDom': white.redDom,
      'coreEdgeDiff': white.coreEdgeDiff,
    },
    'red': <String, double>{
      'meanY': red.meanY,
      'brightFrac': red.brightFrac,
      'sat': red.sat,
      'redDom': red.redDom,
      'coreEdgeDiff': red.coreEdgeDiff,
    },
  };

  factory LampBaseline.fromJson(Map<String, Object?> json) {
    FrameFeatures read(Object? raw) {
      final Map<String, dynamic> m = (raw! as Map).cast<String, dynamic>();
      double value(String key) => (m[key]! as num).toDouble();
      return FrameFeatures(
        meanY: value('meanY'),
        brightFrac: value('brightFrac'),
        sat: value('sat'),
        redDom: value('redDom'),
        coreEdgeDiff: value('coreEdgeDiff'),
        sampleCount: 0,
      );
    }

    return LampBaseline(
      white: read(json['white']),
      red: read(json['red']),
      frameCount: (json['frame_count']! as num).toInt(),
    );
  }

  @override
  String toString() => 'LampBaseline(frames=$frameCount, white=$white, red=$red)';
}
