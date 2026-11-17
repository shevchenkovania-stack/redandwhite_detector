import 'dart:typed_data';

import '../camera/frame_source.dart';
import '../models/frame_features.dart';
import '../models/lamp_config.dart';
import '../models/roi.dart';

/// Один отсчёт пикселя, переиспользуемый без аллокаций на каждый пиксель.
final class _Sample {
  double y = 0;
  double r = 0;
  double g = 0;
  double b = 0;
}

/// Доступ к пикселям кадра в формате, который реально пришёл с камеры.
abstract class _PixelSource {
  void read(int x, int y, _Sample out);
}

/// YUV420 (Android, ImageFormatGroup.yuv420): Y + U/V c учётом row и pixel
/// stride, конверсия BT.601.
final class _YuvSource implements _PixelSource {
  _YuvSource(this._frame, {required this.fullRange});

  final RawLampFrame _frame;
  final bool fullRange;

  static const double _studioMin = 16;
  static const double _studioRange = 219;
  static const double _chromaNull = 128;
  static const double _kr = 1.402;
  static const double _kg = 0.714136;
  static const double _kb = 1.772;
  static const double _kgGreenU = 0.344136;

  Uint8List? get _luma => _frame.luma;

  @override
  void read(int x, int y, _Sample out) {
    final Uint8List? luma = _luma;
    if (luma == null) {
      return;
    }
    final int stride = _frame.lumaStride ?? _frame.width;
    final int lumaIndex = y * stride + x;
    if (lumaIndex >= luma.length) {
      return;
    }
    final double rawY = luma[lumaIndex].toDouble();
    final double adjustedY = fullRange
        ? rawY
        : ((rawY - _studioMin) * 255 / _studioRange).clamp(0.0, 255.0);

    final double chromaY = (y >> 1).toDouble();
    final double chromaX = (x >> 1).toDouble();
    final double u = _chromaAt(_frame.chromaU, chromaX, chromaY);
    final double v = _chromaAt(_frame.chromaV, chromaX, chromaY);

    out.y = adjustedY;
    out.r = (adjustedY + _kr * (v - _chromaNull)).clamp(0.0, 255.0);
    out.g = (adjustedY - _kgGreenU * (u - _chromaNull) - _kg * (v - _chromaNull)).clamp(0.0, 255.0);
    out.b = (adjustedY + _kb * (u - _chromaNull)).clamp(0.0, 255.0);
  }

  double _chromaAt(Uint8List? plane, double x, double y) {
    if (plane == null) {
      return _chromaNull;
    }
    final int rowStride = _frame.chromaStride ?? (_frame.width >> 1);
    final int pixelStride = _frame.chromaPixelStride ?? 1;
    final int index = (y * rowStride + x * pixelStride).round();
    if (index < 0 || index >= plane.length) {
      return _chromaNull;
    }
    return plane[index].toDouble();
  }
}

/// BGRA8888 (iOS, ImageFormatGroup.bgra8888).
final class _BgraSource implements _PixelSource {
  _BgraSource(this._frame);

  final RawLampFrame _frame;

  static const double _lumaR = 0.299;
  static const double _lumaG = 0.587;
  static const double _lumaB = 0.114;

  @override
  void read(int x, int y, _Sample out) {
    final Uint8List? bytes = _frame.pixels;
    if (bytes == null) {
      return;
    }
    final int rowStride = _frame.rowStride ?? _frame.width * 4;
    final int pixelStride = _frame.pixelStride ?? 4;
    final int index = y * rowStride + x * pixelStride;
    if (index + 2 >= bytes.length) {
      return;
    }
    final double b = bytes[index].toDouble();
    final double g = bytes[index + 1].toDouble();
    final double r = bytes[index + 2].toDouble();
    out.b = b;
    out.g = g;
    out.r = r;
    out.y = _lumaR * r + _lumaG * g + _lumaB * b;
  }
}

/// Вычисление [FrameFeatures] по ROI с подвыборкой каждый N-й пиксель.
///
/// Никакого декодирования видео и никаких внешних библиотек: только обход
/// нужных пикселей.
class FeatureExtractor {
  FeatureExtractor(this.config);

  /// Пороги можно менять на лету (подбор по записанным CSV).
  LampConfig config;

  /// Знаменатель, ниже которого насыщенность не считаем (защита от 0/0).
  static const double _minChannelForSat = 1.0;

  /// Признаки обеих ламп одного кадра. [roi] задан в координатах превью и
  /// переносится в координаты кадра через [mapping].
  LampFrame extract(RawLampFrame frame, RoiLayout roi, FrameMapping mapping) => LampFrame(
    timestamp: frame.receivedAt,
    white: extractRoi(frame, mapping.toFrameRoi(roi.white)),
    red: extractRoi(frame, mapping.toFrameRoi(roi.red)),
    exposureTimeNs: frame.exposureTimeNs,
    sensorSensitivity: frame.sensorSensitivity,
  );

  /// Признаки одной ROI в координатах самого кадра.
  FrameFeatures extractRoi(RawLampFrame frame, LampRoi roi) {
    final _PixelSource source = switch (frame.format) {
      PixelFormatKind.yuv420 => _YuvSource(frame, fullRange: config.yuvFullRange),
      PixelFormatKind.bgra8888 => _BgraSource(frame),
      PixelFormatKind.unsupported => _EmptySource(),
    };

    final int left = (roi.left * frame.width).round();
    final int top = (roi.top * frame.height).round();
    final int right = (roi.right * frame.width).round();
    final int bottom = (roi.bottom * frame.height).round();

    final int coreLeft = (roi.left + roi.width * (1 - config.coreSideRatio) / 2).round();
    final int coreRight = (roi.left + roi.width * (1 + config.coreSideRatio) / 2).round();
    final int coreTop = (roi.top + roi.height * (1 - config.coreSideRatio) / 2).round();
    final int coreBottom = (roi.top + roi.height * (1 + config.coreSideRatio) / 2).round();

    final _Sample sample = _Sample();
    final int step = config.subsampleStep;

    double sumY = 0;
    double sumR = 0;
    double sumG = 0;
    double sumB = 0;
    double sumSat = 0;
    double sumCoreY = 0;
    double sumRingY = 0;
    int count = 0;
    int brightCount = 0;
    int coreCount = 0;
    int ringCount = 0;

    for (int y = top; y < bottom; y += step) {
      if (y < 0) {
        continue;
      }
      if (y >= frame.height) {
        break;
      }
      final bool rowInCore = y >= coreTop && y < coreBottom;
      for (int x = left; x < right; x += step) {
        if (x < 0) {
          continue;
        }
        if (x >= frame.width) {
          break;
        }
        source.read(x, y, sample);
        count++;
        sumY += sample.y;
        sumR += sample.r;
        sumG += sample.g;
        sumB += sample.b;
        if (sample.y >= config.brightY) {
          brightCount++;
        }
        final double maxChannel = sample.r > sample.g
            ? (sample.r > sample.b ? sample.r : sample.b)
            : (sample.g > sample.b ? sample.g : sample.b);
        final double minChannel = sample.r < sample.g
            ? (sample.r < sample.b ? sample.r : sample.b)
            : (sample.g < sample.b ? sample.g : sample.b);
        sumSat += maxChannel < _minChannelForSat
            ? 0
            : (maxChannel - minChannel) / maxChannel;

        if (rowInCore && x >= coreLeft && x < coreRight) {
          sumCoreY += sample.y;
          coreCount++;
        } else {
          sumRingY += sample.y;
          ringCount++;
        }
      }
    }

    if (count == 0) {
      return FrameFeatures.zero;
    }

    return FrameFeatures(
      meanY: sumY / count,
      brightFrac: brightCount / count,
      sat: sumSat / count,
      redDom: sumR / count - (sumG + sumB) / 2 / count,
      coreEdgeDiff: (coreCount == 0 || ringCount == 0) ? 0 : sumCoreY / coreCount - sumRingY / ringCount,
      sampleCount: count,
    );
  }
}

final class _EmptySource implements _PixelSource {
  @override
  void read(int x, int y, _Sample out) {
    out.y = 0;
    out.r = 0;
    out.g = 0;
    out.b = 0;
  }
}
