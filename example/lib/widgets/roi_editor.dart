import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Перетаскиваемые ROI поверх превью.
///
/// Координаты нормализованы (0..1) относительно области превью, поэтому ROI
/// переживают смену разрешения и поворота. Второй жест (за уголок) меняет
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: <Widget>[
            _box(layout.white, label: 'WHITE', color: Colors.white, size: size, isWhite: true),
            _box(layout.red, label: 'RED', color: Colors.redAccent, size: size, isWhite: false),
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
  }) {
    void apply(LampRoi next) =>
        onChanged(isWhite ? layout.withWhite(next) : layout.withRed(next));

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

    return Positioned(
      left: roi.left * size.width,
      top: roi.top * size.height,
      width: roi.width * size.width,
      height: roi.height * size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onPanUpdate: move,
              onTapUp: (_) => onCommit?.call(),
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
          Positioned(
            right: -_handleSize / 3,
            bottom: -_handleSize / 3,
            child: GestureDetector(
              onPanUpdate: resize,
              child: Container(
                width: _handleSize,
                height: _handleSize,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const Icon(Icons.open_in_full, size: 14, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
