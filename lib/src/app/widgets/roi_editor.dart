import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Перетаскивание ROI поверх превью — вид и поведение первого стендового
/// варианта: рамка, подпись и кружок со стрелками `open_in_full` в углу.
///
/// Координаты нормализованы (0..1) относительно области превью, поэтому ROI
/// переживают смену разрешения и поворота. Брать можно не только по видимому
/// прямоугольнику: вокруг каждой зоны есть невидимое поле захвата [_grab], но
/// оно не залезает ни на соседнюю рамку, ни за край кадра — иначе пальцем по
/// лампе попадаешь ручкой размера соседней.
///
/// Тело рамки ведёт переезд, кружок в углу — размер, двойной тап увеличивает,
/// долгое нажатие уменьшает. Первый `delta` считается от точки касания
/// (`DragStartBehavior.down`), поэтому рамка догоняет палец сразу, а не после
/// «мёртвых» 18 пунктов.
///
/// [syncSize] — замок размера: вторая рамка получает ровно тот же размер
/// вокруг СВОЕГО центра, положения при этом не связываются.
///
/// Любая правка проходит через [RoiLayout.separated]: пересечения зон не
/// бывает — касание краями законно, наезд нет, иначе одна и та же пиксельная
/// строка засчитывалась бы обеим лампам.
///
/// [onActiveChanged] говорит, когда палец ведёт рамку: анализ кадра стоит
/// десятки миллисекунд на том же потоке, где живёт жест, и на время наводки
/// сессия перестаёт считать кадры. [onCommit] — конец наводки.
class RoiEditor extends StatelessWidget {
  const RoiEditor({
    super.key,
    required this.layout,
    required this.onChanged,
    this.onCommit,
    this.onActiveChanged,
    this.syncSize = false,
  });

  final RoiLayout layout;
  final ValueChanged<RoiLayout> onChanged;

  /// Конец наводки: сохранить и (в сессии) один раз сбросить то, что набрано
  /// по ПРЕЖНИМ пикселям.
  final VoidCallback? onCommit;

  /// `true` — палец ведёт рамку, `false` — отпустил.
  final ValueChanged<bool>? onActiveChanged;

  /// Замок размера: обе зоны всегда одного размера.
  final bool syncSize;

  static const double _handleSize = 26;

  /// Поле вокруг кружка ручки: зона касания 44 логических пункта.
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
    /// Новый набор после правки рамки: сначала замок (вторая рамка принимает
    /// этот размер вокруг своего центра), потом разведение — пересечения в
    /// наборе не остаётся.
    void apply(LampRoi next) {
      onChanged(
        layout.separated(
          next,
          nextIsWhite: isWhite,
          other: syncSize ? other.withSize(next.width, next.height) : null,
        ),
      );
    }

    /// Начало и конец жеста. Кадры на время наводки не считаются, иначе
    /// анализ втискивается между двумя событиями пальца и рамки едут рывками.
    void start() => onActiveChanged?.call(true);

    void commit() {
      onActiveChanged?.call(false);
      onCommit?.call();
    }

    void move(DragUpdateDetails details) {
      start();
      apply(
        roi.moved(
          details.delta.dx / size.width,
          details.delta.dy / size.height,
        ),
      );
    }

    void resize(DragUpdateDetails details) {
      start();
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
    // Кружок ручки ставим в центр угла: половина зоны касания приходит на
    // рамку, половина — в пустоту рядом. Шанс на маленькой рамке выше попасть
    // ручкой размера, чем потерять её.
    final double handleRight = math.max(
      0.0,
      grab.right - (_handleSize + 2 * _handlePad) / 2,
    );
    final double handleBottom = math.max(
      0.0,
      grab.bottom - (_handleSize + 2 * _handlePad) / 2,
    );

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
              // когда жест признан драгом: рамка не стоит «мёртвые» 18
              // пунктов, а догоняет палец сразу.
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: move,
              onPanEnd: (_) => commit(),
              onTapUp: (_) => commit(),
              // Размер вверх рукой: двойной тап — увеличить, долгое нажатие —
              // уменьшить. Точнее рукой, чем маленьким уголком лампы.
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
          // 2. Видимая рамка — ровно на месте ROI. IgnorePointer, чтобы она
          // не отнимала палец у слоя перетаскивания.
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
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 3. Кнопка размера: зона касания 44 логических пункта вместо 26 и
          // половина её лежит в пустоте за углом рамки. Ручка видима и
          // оставалась бы поверх превю — поэтому она внутри рамки целиком.
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
                      child: Icon(
                        Icons.open_in_full,
                        size: 14,
                        color: Colors.white,
                      ),
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

  /// Граница невидимой зоны захвата с каждой стороны. Она не больше [_grab],
  /// не залезает на вторую рамку (иначе пальцем рядом с соседней лампой
  /// двигалась бы не та рамка) и не выходит за край превью (иначе ручка
  /// размера обрезалась бы ClipRRect).
  EdgeInsets _grabInsets(LampRoi roi, LampRoi other, Size size) {
    double side(double roomPx, double gapPx) =>
        math.min(_grab, math.min(roomPx, gapPx)).clamp(0.0, _grab).toDouble();
    return EdgeInsets.only(
      left: side(roi.left * size.width, (roi.left - other.right) * size.width),
      top: side(roi.top * size.height, (roi.top - other.bottom) * size.height),
      right: side(
        (1 - roi.right) * size.width,
        (other.left - roi.right) * size.width,
      ),
      bottom: side(
        (1 - roi.bottom) * size.height,
        (other.top - roi.bottom) * size.height,
      ),
    );
  }
}
