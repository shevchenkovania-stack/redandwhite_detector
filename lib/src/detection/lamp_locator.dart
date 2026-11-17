import '../camera/frame_source.dart';
import '../models/lamp_config.dart';
import '../models/roi.dart';
import 'feature_extractor.dart';

/// Автоматический поиск зон двух ламп по одному кадру.
///
/// Кадр делится на сетку, для каждой клетки признаки считаются через
/// [FeatureExtractor.extractRoi]. Красная лампа — клетка с максимумом
/// [FrameFeatures.redDom] (красный пластик виден даже выключенным). Белая — самая
/// светлая клетка, но в стороне от уже найденной красной (чтобы не схватить ядро
/// красной лампы или отсвет от неё).
///
/// Искать нужно по спокойному кадру (обе лампы выключены): на залитой вспышке
/// сцена целиком становится красной/белой, и «самое красное пятно» может оказаться
/// рукой или столом, а не лампой.
///
/// Это вспомогательный инструмент настройки: он не меняет формулы whiteScore /
/// redScore и не участвует в детекции во время игры — только задаёт [RoiLayout].
class LampLocator {
  const LampLocator({this.cells = 24, this.boxSize = 0.28});

  /// Сторона клетки сетки = 1/[cells] кадра.
  final int cells;

  /// Размер итогового ROI как доля стороны кадра.
  final double boxSize;

  RoiLayout locate(
    RawLampFrame frame,
    FeatureExtractor extractor,
    FrameMapping mapping,
    LampConfig config,
  ) {
    final double cell = 1.0 / cells;
    final List<List<double>> meanY = <List<double>>[];
    final List<List<double>> redDom = <List<double>>[];
    final List<List<double>> sat = <List<double>>[];

    for (int cy = 0; cy < cells; cy++) {
      final rowY = <double>[];
      final rowR = <double>[];
      final rowS = <double>[];
      for (int cx = 0; cx < cells; cx++) {
        final LampRoi previewCell =
            LampRoi(left: cx * cell, top: cy * cell, width: cell, height: cell);
        final features = extractor.extractRoi(frame, mapping.toFrameRoi(previewCell));
        rowY.add(features.meanY);
        rowR.add(features.redDom);
        rowS.add(features.sat);
      }
      meanY.add(rowY);
      redDom.add(rowR);
      sat.add(rowS);
    }

    // 1. Красная: максимум redDom.
    int redCx = 0;
    int redCy = 0;
    double bestRed = -1e9;
    for (int cy = 0; cy < cells; cy++) {
      for (int cx = 0; cx < cells; cx++) {
        if (redDom[cy][cx] > bestRed) {
          bestRed = redDom[cy][cx];
          redCx = cx;
          redCy = cy;
        }
      }
    }

    // 2. Белая: максимум яркости в стороне от красной.
    final double minDist = cells * 0.25;
    int whiteCx = 0;
    int whiteCy = 0;
    double bestWhite = -1e9;
    for (int cy = 0; cy < cells; cy++) {
      for (int cx = 0; cx < cells; cx++) {
        final double dx = (cx - redCx).toDouble();
        final double dy = (cy - redCy).toDouble();
        if ((dx * dx + dy * dy) < minDist * minDist) {
          continue; // не пересекаться с красной
        }
        final double score = sat[cy][cx] <= config.whiteSatMax ? meanY[cy][cx] : 0;
        if (score > bestWhite) {
          bestWhite = score;
          whiteCx = cx;
          whiteCy = cy;
        }
      }
    }

    return RoiLayout(white: _box(whiteCx, whiteCy), red: _box(redCx, redCy));
  }

  LampRoi _box(int cx, int cy) => LampRoi(
    left: (cx + 0.5) / cells - boxSize / 2,
    top: (cy + 0.5) / cells - boxSize / 2,
    width: boxSize,
    height: boxSize,
  ).normalized();
}
