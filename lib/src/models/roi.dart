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
  LampRoi moved(double dx, double dy) => LampRoi(
    left: left + dx,
    top: top + dy,
    width: width,
    height: height,
  ).normalized();

  /// Возвращает ROI с новым размером, прижатый к правому нижнему углу так,
  /// чтобы он не выходил за границы кадра.
  LampRoi resized(double width, double height) =>
      LampRoi(left: left, top: top, width: width, height: height).normalized();

  /// ROI с новым размером вокруг того же центра — это «под замок»: обе зоны
  /// получают ОДИН размер, оставаясь каждая на своей лампе.
  LampRoi withSize(double width, double height) {
    final double w = width <= 0 ? this.width : width;
    final double h = height <= 0 ? this.height : height;
    final Offset c = center;
    return LampRoi(
      left: c.dx - w / 2,
      top: c.dy - h / 2,
      width: w,
      height: h,
    ).normalized();
  }

  /// Изменяет размер вокруг центра (центр остаётся на месте) — удобно для
  /// точной подгонки зоны под колпак без перетаскивания уголка пальцем.
  LampRoi scaledAboutCenter(double factor) {
    final double k = factor <= 0 ? 1.0 : factor;
    final double w = (width * k).clamp(minSize, 1.0);
    final double h = (height * k).clamp(minSize, 1.0);
    final Offset c = center;
    return LampRoi(
      left: c.dx - w / 2,
      top: c.dy - h / 2,
      width: w,
      height: h,
    ).normalized();
  }

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
      point.dx >= left &&
      point.dx <= right &&
      point.dy >= top &&
      point.dy <= bottom;

  /// Пересекается ли эта зона с другой. Касание краями — НЕ пересечение:
  /// рамки вплотную друг к другу законны и оператором именно к этому и
  /// ведут (лампы стоят рядом).
  bool overlaps(LampRoi other) =>
      left < other.right &&
      other.left < right &&
      top < other.bottom &&
      other.top < bottom;

  /// Длина вторжения по X и по Y: ноль (или меньше), если по этой оси зоны
  /// не пересекаются вовсе.
  double penetrationX(LampRoi other) =>
      (right < other.right ? right : other.right) -
      (left > other.left ? left : other.left);

  double penetrationY(LampRoi other) =>
      (bottom < other.bottom ? bottom : other.bottom) -
      (top > other.top ? top : other.top);

  /// Та же зона, сдвинутая ПО ОСИ [horizontal] из-под [blocker] до касания его
  /// края; отступает в сторону, противоположную центру `blocker`, и зажимается
  /// в границах кадра. По второй оси рамка не двигается.
  LampRoi pushedOutOf(LampRoi blocker, {required bool horizontal}) {
    if (horizontal) {
      final double newLeft = center.dx <= blocker.center.dx
          ? blocker.left - width
          : blocker.right;
      return LampRoi(
        left: newLeft,
        top: top,
        width: width,
        height: height,
      ).normalized();
    }
    final double newTop = center.dy <= blocker.center.dy
        ? blocker.top - height
        : blocker.bottom;
    return LampRoi(
      left: left,
      top: newTop,
      width: width,
      height: height,
    ).normalized();
  }

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

  RoiLayout withWhite(LampRoi roi) =>
      RoiLayout(white: roi.normalized(), red: red);
  RoiLayout withRed(LampRoi roi) =>
      RoiLayout(white: white, red: roi.normalized());

  /// Набор, в котором правка одной рамки НЕ оставляет пересечения.
  ///
  /// Лампы стоят рядом, поэтому при наводке рамки неизбежно едут друг в
  /// друга, а пересечение означало бы одно и то же: пиксельная строка
  /// засчитывается и за белую, и за красную, вспышка соседней лампы попадает
  /// в обе зоны. Касание краями при этом законно — именно к нему и ведёт
  /// оператор, — поэтому выпихивание останавливается на крае, а не отступает
  /// с запасом.
  ///
  /// [next] — рамка под пальцем ([nextIsWhite] говорит, какая): её положение
  /// приоритетно, разводить в первую очередь её. [other] — вторая рамка,
  /// уже с новым размером под замком. Кандидатов хватает: толкнуть ведомую
  /// рамку по оси наименьшего вторжения, по другой оси, а если она упёрлась в
  /// край кадра — сдвинуть вторую. Если рамки физически не влазятся в кадр
  /// раздельно, берётся вариант с наименьшим остаточным перекрытием.
  RoiLayout separated(
    LampRoi next, {
    required bool nextIsWhite,
    LampRoi? other,
  }) {
    final LampRoi moved = next.normalized();
    final LampRoi blocker = (other ?? (nextIsWhite ? red : white)).normalized();
    if (!moved.overlaps(blocker)) {
      return _pair(moved, blocker, nextIsWhite);
    }
    final bool shallowFirst =
        moved.penetrationX(blocker) <= moved.penetrationY(blocker);
    final List<RoiLayout> candidates = <RoiLayout>[
      _pair(
        moved.pushedOutOf(blocker, horizontal: shallowFirst),
        blocker,
        nextIsWhite,
      ),
      _pair(
        moved.pushedOutOf(blocker, horizontal: !shallowFirst),
        blocker,
        nextIsWhite,
      ),
      _pair(
        moved,
        blocker.pushedOutOf(moved, horizontal: shallowFirst),
        nextIsWhite,
      ),
      _pair(
        moved,
        blocker.pushedOutOf(moved, horizontal: !shallowFirst),
        nextIsWhite,
      ),
    ];
    RoiLayout best = _pair(moved, blocker, nextIsWhite);
    double bestScore = _crossArea(moved, blocker);
    for (final RoiLayout candidate in candidates) {
      final double score = _crossArea(candidate.white, candidate.red);
      if (score <= 0) {
        return candidate;
      }
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  /// Свести рамки вплотную: минимальный зазор по одной оси, вторая ось не
  /// трогается. Пара ставится вокруг середины между её текущими центрами, так
  /// что ни одна лампа не уезжает из своего места кадра.
  ///
  /// Ось выбирается по тому, как рамки стоят: рядом по горизонтали — сводим по
  /// X, друг над другом — по Y, вразноосно — по той, где зазор меньше. Если по
  /// выбранной оси обе рамки в кадр не влазятся, берётся другая; когда не
  /// влазятся никуда, остаётся выбранная — [LampRoi.normalized] прижмёт обе
  /// рамки к краям, и это всё, что физически возможно.
  RoiLayout adjacent({double gap = adjacentGap}) {
    final double gapX = _gapX(white, red);
    final double gapY = _gapY(white, red);
    bool horizontal = gapX > 0 && gapY == 0
        ? true
        : gapY > 0 && gapX == 0
        ? false
        : gapX <= gapY;
    final bool fitX = white.width + red.width + gap <= 1.0;
    final bool fitY = white.height + red.height + gap <= 1.0;
    if (horizontal && !fitX && fitY) {
      horizontal = false;
    } else if (!horizontal && !fitY && fitX) {
      horizontal = true;
    }
    final bool whiteFirst = horizontal
        ? white.center.dx <= red.center.dx
        : white.center.dy <= red.center.dy;
    final LampRoi first = whiteFirst ? white : red;
    final LampRoi second = whiteFirst ? red : white;
    final double total = horizontal
        ? first.width + second.width + gap
        : first.height + second.height + gap;
    final double mid = horizontal
        ? (white.center.dx + red.center.dx) / 2
        : (white.center.dy + red.center.dy) / 2;
    double start = mid - total / 2;
    if (start < 0) {
      start = 0;
    }
    final double maxStart = 1.0 - total;
    if (maxStart > 0 && start > maxStart) {
      start = maxStart;
    }
    final LampRoi a = horizontal
        ? LampRoi(
            left: start,
            top: first.top,
            width: first.width,
            height: first.height,
          ).normalized()
        : LampRoi(
            left: first.left,
            top: start,
            width: first.width,
            height: first.height,
          ).normalized();
    final LampRoi b = horizontal
        ? LampRoi(
            left: a.right + gap,
            top: second.top,
            width: second.width,
            height: second.height,
          ).normalized()
        : LampRoi(
            left: second.left,
            top: a.bottom + gap,
            width: second.width,
            height: second.height,
          ).normalized();
    return whiteFirst
        ? RoiLayout(white: a, red: b)
        : RoiLayout(white: b, red: a);
  }

  /// Просвет, который сведение оставляет между рамками, — доля кадра. Впритык
  /// было бы геометрически точнее, но оператор обязан видеть, что зоны ДВЕ: без
  /// зазора границы сливаются в одну линию и непонятно, где чужой край. Две
  /// сотых кадра — это ~20 пикселей, достаточно, чтобы различить.
  static const double adjacentGap = 0.02;

  static RoiLayout _pair(LampRoi moved, LampRoi other, bool movedIsWhite) =>
      movedIsWhite
      ? RoiLayout(white: moved, red: other)
      : RoiLayout(white: other, red: moved);

  /// Площадь перекрытия двух рамок; ноль — если они не пересекаются.
  static double _crossArea(LampRoi a, LampRoi b) {
    final double px = a.penetrationX(b);
    final double py = a.penetrationY(b);
    if (px <= 0 || py <= 0) {
      return 0;
    }
    return px * py;
  }

  /// Зазор по X; ноль, если проекции рамок на эту ось пересекаются.
  static double _gapX(LampRoi a, LampRoi b) => a.right <= b.left
      ? b.left - a.right
      : b.right <= a.left
      ? a.left - b.right
      : 0;

  static double _gapY(LampRoi a, LampRoi b) => a.bottom <= b.top
      ? b.top - a.bottom
      : b.bottom <= a.top
      ? a.top - b.bottom
      : 0;

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
  const FrameMapping({
    required this.quarterTurns,
    this.mirrorHorizontal = false,
  });

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
  String toString() =>
      'FrameMapping(turns=$quarterTurns, mirror=$mirrorHorizontal)';
}
