import 'dart:ui' show Offset;

/// Прямоугольник интересующей зоны (ROI) в нормализованных координатах кадра.
///
/// Все значения 0..1 и не зависят от разрешения: 0,0 — левый верхний угол
/// кадра, 1,1 — правый нижний.
class LampRoi {
  const LampRoi({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  Offset get center => Offset(left + width / 2, top + height / 2);

  /// Возвращает ROI, сдвинутый на [dx]/[dy] и зажатый в границы кадра.
  LampRoi moved(double dx, double dy) =>
      LampRoi(left: left + dx, top: top + dy, width: width, height: height).normalized();

  /// Возвращает ROI с новым размером, прижатый к правому нижнему углу так,
  /// чтобы он не выходил за границы кадра.
  LampRoi resized(double width, double height) =>
      LampRoi(left: left, top: top, width: width, height: height).normalized();

  /// Минимальный размер зоны, чтобы подвыборка каждый N-й пиксель давала
  /// осмысленное число отсчётов.
  static const double minSize = 0.02;

  /// Зажимает координаты в 0..1 и гарантирует минимальный размер.
  LampRoi normalized() {
    final double w = width.clamp(minSize, 1.0);
    final double h = height.clamp(minSize, 1.0);
    return LampRoi(
      left: left.clamp(0.0, 1.0 - w),
      top: top.clamp(0.0, 1.0 - h),
      width: w,
      height: h,
    );
  }

  bool contains(Offset point) =>
      point.dx >= left && point.dx <= right && point.dy >= top && point.dy <= bottom;

  Map<String, double> toJson() => <String, double>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  factory LampRoi.fromJson(Map<String, dynamic> json) => LampRoi(
    left: (json['left']! as num).toDouble(),
    top: (json['top']! as num).toDouble(),
    width: (json['width']! as num).toDouble(),
    height: (json['height']! as num).toDouble(),
  );

  @override
  String toString() =>
      'LampRoi(l=${left.toStringAsFixed(3)}, t=${top.toStringAsFixed(3)}, '
      'w=${width.toStringAsFixed(3)}, h=${height.toStringAsFixed(3)})';
}

/// Пара ROI: зона белой и зона красной лампы.
class RoiLayout {
  const RoiLayout({required this.white, required this.red});

  final LampRoi white;
  final LampRoi red;

  /// Дефолт по реальной записи: лампы ~15-20% кадра, вертикальная съёмка,
  /// белая выше красной.
  static const RoiLayout defaults = RoiLayout(
    white: LampRoi(left: 0.38, top: 0.16, width: 0.34, height: 0.26),
    red: LampRoi(left: 0.10, top: 0.56, width: 0.34, height: 0.26),
  );

  RoiLayout withWhite(LampRoi roi) => RoiLayout(white: roi.normalized(), red: red);
  RoiLayout withRed(LampRoi roi) => RoiLayout(white: white, red: roi.normalized());

  Map<String, Object?> toJson() => <String, Object?>{
    'white': white.toJson(),
    'red': red.toJson(),
  };

  factory RoiLayout.fromJson(Map<String, Object?> json) => RoiLayout(
    white: LampRoi.fromJson((json['white']! as Map).cast<String, dynamic>()),
    red: LampRoi.fromJson((json['red']! as Map).cast<String, dynamic>()),
  );
}

/// Поворот и отражение между нормализованными координатами превью и координатами
/// пикселей кадра из image stream.
///
/// Плагин `camera` отдаёт кадры image stream в ориентации сенсора, а превью
/// поворачивается под ориентацию устройства. Без этого соответствия ROI
/// «смотрела» бы не туда.
class FrameMapping {
  const FrameMapping({required this.quarterTurns, this.mirrorHorizontal = false});

  /// Кадры уже приходят в той же ориентации, что и превью (тесты, файлы).
  static const FrameMapping identity = FrameMapping(quarterTurns: 0);

  /// Число поворотов на 90° по часовой стрелке от превью к кадру.
  final int quarterTurns;

  /// Фронтальная камера даёт зеркальное изображение.
  final bool mirrorHorizontal;

  /// Нормализованная точка превью -> нормализованная точка кадра.
  Offset toFrame(Offset point) {
    double x = point.dx;
    double y = point.dy;
    if (mirrorHorizontal) {
      x = 1 - x;
    }
    for (int turn = 0; turn < quarterTurns % 4; turn++) {
      final double nextX = y;
      y = 1 - x;
      x = nextX;
    }
    return Offset(x, y);
  }

  /// ROI из координат превью в координаты кадра (смена ширины/высоты при 90°).
  LampRoi toFrameRoi(LampRoi roi) {
    final Offset a = toFrame(Offset(roi.left, roi.top));
    final Offset b = toFrame(Offset(roi.right, roi.bottom));
    return LampRoi(
      left: a.dx < b.dx ? a.dx : b.dx,
      top: a.dy < b.dy ? a.dy : b.dy,
      width: (a.dx - b.dx).abs(),
      height: (a.dy - b.dy).abs(),
    ).normalized();
  }

  @override
  String toString() => 'FrameMapping(turns=$quarterTurns, mirror=$mirrorHorizontal)';
}
