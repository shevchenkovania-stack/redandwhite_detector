import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Проверка яркостных признаков: они измеряют форму распределения яркости, а
/// не цвет пикселя, и должны быть одинаковыми на YUV (Android) и BGRA (iOS).
///
/// Кадры собираются вручную: ровное поле, локальное пятно, пересвет, строка с
/// выравнивающим хвостом. Порогов здесь нет — только «что измерилось».
void main() {
  const LampRoi fullFrame = LampRoi(left: 0, top: 0, width: 1, height: 1);
  const int w = 40;
  const int h = 20;

  RawLampFrame yuv(Uint8List luma, {int? stride}) => RawLampFrame(
    receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
    width: w,
    height: h,
    format: PixelFormatKind.yuv420,
    luma: luma,
    lumaStride: stride,
  );

  /// Кадр, где верхняя `fraction` строк ярче остального поля.
  RawLampFrame blob(double fraction, int bright, int dark) {
    final Uint8List luma = Uint8List(w * h)..fillRange(0, w * h, dark);
    final int rows = (h * fraction).round();
    for (int y = 0; y < rows; y++) {
      luma.fillRange(y * w, (y + 1) * w, bright);
    }
    return yuv(luma);
  }

  FeatureExtractor extractor({bool fullRange = true}) =>
      FeatureExtractor(LampConfig(yuvFullRange: fullRange));

  group('яркостные признаки', () {
    test('ровное поле: процентиль равен среднему, разброса и пересвета нет', () {
      final Uint8List luma = Uint8List(w * h)..fillRange(0, w * h, 60);
      final FrameFeatures f = extractor().extractRoi(yuv(luma), fullFrame);
      expect(f.meanY, 60);
      expect(f.p90Luma, 60);
      expect(f.lumaStdDev, 0);
      expect(f.clippedRatio, 0);
    });

    test('локальное пятно: p90 уходит далеко от среднего — это и есть форма', () {
      // 240, а не 255: ниже порога клиппинга, чтобы пересвет не примешивался
      // к проверке формы распределения.
      final FrameFeatures f = extractor().extractRoi(blob(0.2, 240, 60), fullFrame);
      expect(f.p90Luma, 240);
      expect(f.meanY, 96);
      expect(f.lumaStdDev, greaterThan(60));
      expect(f.clippedRatio, 0);
    });

    test('пересвет: clippedRatio = 1, и это признак качества кадра, а не лампы', () {
      final Uint8List luma = Uint8List(w * h)..fillRange(0, w * h, 255);
      final FrameFeatures f = extractor().extractRoi(yuv(luma), fullFrame);
      expect(f.clippedRatio, 1);
      expect(f.p90Luma, 255);
      expect(f.lumaStdDev, 0);
    });

    test('rowStride больше ширины: хвост строки не попадает в измерение', () {
      final int stride = w + 7;
      final Uint8List luma = Uint8List(stride * h)..fillRange(0, stride * h, 99);
      for (int y = 0; y < h; y++) {
        // Реальные пиксели строки — 40, дальше выравнивающий мусор.
        luma.fillRange(y * stride, y * stride + w, 60);
      }
      final FrameFeatures f = extractor().extractRoi(yuv(luma, stride: stride), fullFrame);
      expect(f.meanY, 60);
      expect(f.p90Luma, 60);
    });

    test('limited range: 16..235 растягивается в те же 0..255', () {
      final Uint8List luma = Uint8List(w * h)..fillRange(0, w * h, 235);
      final FrameFeatures studio = extractor(fullRange: false).extractRoi(yuv(luma), fullFrame);
      expect(studio.meanY, closeTo(255, 0.5));
      expect(studio.clippedRatio, 1);
    });

    test('BGRA даёт сопоставимую яркость с YUV на том же белом', () {
      final Uint8List bytes = Uint8List(w * h * 4);
      for (int i = 0; i < bytes.length; i += 4) {
        bytes[i] = 200; // B
        bytes[i + 1] = 200; // G
        bytes[i + 2] = 200; // R
      }
      final FrameFeatures bgra = extractor().extractRoi(
        RawLampFrame(
          receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
          width: w,
          height: h,
          format: PixelFormatKind.bgra8888,
          pixels: bytes,
        ),
        fullFrame,
      );
      expect(bgra.meanY, closeTo(200, 0.5));
      expect(bgra.p90Luma, 200);
      expect(bgra.lumaStdDev, 0);
    });
  });

  group('CSV v4', () {
    test('новое число колонок и яркость колец переживают запись/чтение', () {
      final FeatureCsvRow row = FeatureCsvRow(
        timestampMs: 1000,
        state: 'whiteOn',
        calibrationStep: 'white_on',
        white: const FrameFeatures(
          meanY: 120,
          sampleCount: 400,
          p90Luma: 210,
          lumaStdDev: 33,
          clippedRatio: 0.25,
        ),
        red: const FrameFeatures(meanY: 40, sampleCount: 400),
        whiteRing: const FrameFeatures(
          meanY: 80,
          sampleCount: 100,
          p90Luma: 130,
          lumaStdDev: 12,
          clippedRatio: 0.1,
        ),
      );
      final String line = row.toCsvLine();
      expect(line.split(','), hasLength(FeatureCsvRow.currentColumnCount));

      final FeatureCsvRow back = FeatureCsvRow.parse(line);
      expect(back.white.p90Luma, 210);
      expect(back.white.lumaStdDev, 33);
      expect(back.white.clippedRatio, 0.25);
      expect(back.whiteRing?.meanY, 80);
      expect(back.whiteRing?.p90Luma, 130);
      // Кольца нет — он и должен остаться нулём, а не выдуманным значением.
      expect(back.redRing, isNull);
    });

    test('старая строка v2 читается: яркость = 0, цветовые доли на месте', () {
      final List<String> parts = FeatureCsvRow(
        timestampMs: 2000,
        state: 'idle',
        white: const FrameFeatures(
          meanY: 100,
          sampleCount: 400,
          whiteFrac: 0.4,
          p90Luma: 180,
        ),
        red: const FrameFeatures(meanY: 50, sampleCount: 400, redFrac: 0.3),
      ).toCsvLine().split(',');
      // Обрезаем до формата v2 — так выглядит запись прошлой сборки.
      final String v2line = parts.take(27).join(',');
      final FeatureCsvRow back = FeatureCsvRow.parse(v2line);
      expect(back.white.whiteFrac, 0.4);
      expect(back.white.p90Luma, 0);
      expect(back.whiteRise, 0);
      expect(back.calibrationStep, '');
    });
  });
}
