import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Перетаскиваемые ROI поверх превью.
///
/// Координаты нормализованы (0..1) относительно области превью, поэтому ROI
/// переживают смену разрешения и поворота. Рамку можно схватить не только
/// внутри прямоугольника, но и в 24 логических пикселях вокруг него — зона
/// захвата не залезает на соседнюю рамку и не выходит за край превью. Первый
/// delta считается от точки касания, поэтому рамка догоняет палец сразу, а не
/// после «мёртвых» 18 пикселей. Второй жест (за кружок на углу) меняет
/// размер. Отпускание пальца фиксирует ROI в настройки.
class RoiEditor extends StatelessWidget {
  const RoiEditor({
    super.key,
    required this.layout,
    required this.onChanged,
    this.onCommit,
  });

  final RoiLayout layout;
  final ValueChanged<RoiLayout> onChanged;
  final VoidCallback? onCommit;

  static const double _handleSize = 26;

  /// Поле вокруг кружка ручки: зона касания 44 логических пикселя.
  static const double _handlePad = 9;

  /// Невидимая зона захвата вокруг рамки.
  static const double _grab = 24;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: <Widget>[
            _box(
              layout.white,
              label: 'WHITE',
              color: Colors.white,
              size: size,
              isWhite: true,
              other: layout.red,
            ),
            _box(
              layout.red,
              label: 'RED',
              color: Colors.redAccent,
              size: size,
              isWhite: false,
              other: layout.white,
            ),
          ],
        );
      },
    );
  }

  Widget _box(
    LampRoi roi, {
    required String label,
    required Color color,
    required Size size,
    required bool isWhite,
    required LampRoi other,
  }) {
    void apply(LampRoi next) =>
        onChanged(isWhite ? layout.withWhite(next) : layout.withRed(next));

    /// Сохраняет рамку на диск. Без этого кадрирование живёт только до
    /// перезапуска приложения и после него рамки возвращаются к старым.
    void commit() => onCommit?.call();

    void move(DragUpdateDetails details) {
      apply(roi.moved(details.delta.dx / size.width, details.delta.dy / size.height));
    }

    void resize(DragUpdateDetails details) {
      apply(
        roi.resized(
          roi.width + details.delta.dx / size.width,
          roi.height + details.delta.dy / size.height,
        ),
      );
    }

    final EdgeInsets grab = _grabInsets(roi, other, size);
    final double boxW = roi.width * size.width;
    final double boxH = roi.height * size.height;
    // Кружок ручки ставим в центр угла рамки: половина зоны касания приходит
    // на рамку, половина — в пустоту рядом. Иначе на маленькой рамке угол
    // почти целиком оказался бы ручкой размера.
    final double handleRight =
        math.max(0.0, grab.right - (_handleSize + 2 * _handlePad) / 2);
    final double handleBottom =
        math.max(0.0, grab.bottom - (_handleSize + 2 * _handlePad) / 2);

    return Positioned(
      left: roi.left * size.width - grab.left,
      top: roi.top * size.height - grab.top,
      width: boxW + grab.left + grab.right,
      height: boxH + grab.top + grab.bottom,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // 1. Слой перетаскивания: вся зона захвата, включая пустые места.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Первый delta считается от точки касания, а не от момента,
              // когда жест признали драгом: рамка не отстаёт на «мёртвые»
              // 18 пикселей, а догоняет палец сразу.
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: move,
              onPanEnd: (_) => commit(),
              onTapUp: (_) => commit(),
              // Размер вокруг центра: двойной тап — увеличить, долгое нажатие —
              // уменьшить. Точнее уголка пальцем, когда лампа мелкая.
              onDoubleTap: () {
                apply(roi.scaledAboutCenter(1.3));
                commit();
              },
              onLongPress: () {
                apply(roi.scaledAboutCenter(1 / 1.3));
                commit();
              },
              child: const SizedBox.expand(),
            ),
          ),
          // 2. Видимая рамка — ровно на месте ROI. IgnorePointer, чтобы она не
          // отнимала палец у слоя перетаскивания.
          Positioned(
            left: grab.left,
            top: grab.top,
            width: boxW,
            height: boxH,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: color, width: 2),
                  color: color.withValues(alpha: 0.12),
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ColoredBox(
                    color: Colors.black54,
                    child: Text(
                      label,
                      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 3. Ручка размера: зона касания 44 логических пикселя вместо 26 и
          // половина её лежит в пустоте за углом рамки. Раньше ручка висела
          // снаружи и обрезалась ClipRRect — теперь она внутри превью всегда.
          Positioned(
            right: handleRight,
            bottom: handleBottom,
            child: GestureDetector(
              onPanUpdate: resize,
              onPanEnd: (_) => commit(),
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              child: Padding(
                padding: const EdgeInsets.all(_handlePad),
                child: SizedBox(
                  width: _handleSize,
                  height: _handleSize,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0xCC000000),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: Icon(Icons.open_in_full, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Ширина невидимой зоны захвата с каждой стороны. Она не больше [_grab],
  /// не залезает на вторую рамку (иначе пальцем рядом с соседней лампой
  /// двигалась бы не та рамка) и не выходит за край превью (иначе ручка
  /// размера обрезалась бы ClipRRect).
  EdgeInsets _grabInsets(LampRoi roi, LampRoi other, Size size) {
    double side(double roomPx, double gapPx) =>
        math.min(_grab, math.min(roomPx, gapPx)).clamp(0.0, _grab).toDouble();
    return EdgeInsets.only(
      left: side(roi.left * size.width, (roi.left - other.right) * size.width),
      top: side(roi.top * size.height, (roi.top - other.bottom) * size.height),
      right: side((1 - roi.right) * size.width, (other.left - roi.right) * size.width),
      bottom: side(
        (1 - roi.bottom) * size.height,
        (other.top - roi.bottom) * size.height,
      ),
    );
  }
}
