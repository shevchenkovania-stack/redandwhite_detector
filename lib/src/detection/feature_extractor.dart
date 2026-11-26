import 'dart:math' as math;
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
    out.g =
        (adjustedY - _kgGreenU * (u - _chromaNull) - _kg * (v - _chromaNull))
            .clamp(0.0, 255.0);
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

  /// Переиспользуемые рабочие буферы одного прохода по ROI. Extractor живёт
  /// столько, сколько сессия, и вызывается последовательно, поэтому буферов
  /// ровно по одному, а не на каждый кадр.
  static const int _maxCoreCells = 1 << 16;
  static const int _histVSlot = 0;
  static const int _histSSlot = 1;
  static const int _histHueSlot = 2;
  static final Int32List _emptyHist = Int32List(0);
  static final Uint8List _emptyMask = Uint8List(0);
  final List<Int32List> _hists = <Int32List>[
    Int32List(256),
    Int32List(64),
    Int32List(16),
  ];
  Uint8List _mask = Uint8List(0);
  Int32List _parent = Int32List(0);

  /// Признаки обеих ламп одного кадра. [roi] задан в координатах превью и
  /// переносится в координаты кадра через [mapping].
  ///
  /// Кольцо вокруг рамки считается всегда, когда включён `ringScale > 1`. На это
  /// есть две причины, и обе настоящие: у ламп светит ореол, а колпак при
  /// включении может даже побледнеть (замер: колпак 0.727 → 0.630, ореол
  /// 0.007 → 0.811), поэтому одной центральной зоне не веришь; и для самого
  /// решения ореол — вторая измеряемая область, без которой восьмимерный вектор
  /// молча съезжается до яркости двух колпаков.
  LampFrame extract(RawLampFrame frame, RoiLayout roi, FrameMapping mapping) {
    final LampRoi white = mapping.toFrameRoi(roi.white);
    final LampRoi red = mapping.toFrameRoi(roi.red);
    final bool withRing = config.ringScale > 1;
    final FrameFeatures whiteCore = extractRoi(frame, white);
    final FrameFeatures redCore = extractRoi(frame, red);
    return LampFrame(
      timestamp: frame.receivedAt,
      white: whiteCore,
      red: redCore,
      whiteRing: withRing ? _halo(frame, white, red, whiteCore) : null,
      redRing: withRing ? _halo(frame, red, white, redCore) : null,
      exposureTimeNs: frame.exposureTimeNs,
      sensorSensitivity: frame.sensorSensitivity,
    );
  }

  /// Ореол своей лампы [roi] с вычтенной чужой лампой [other]; null, если от
  /// кольца оставаться нечего.
  FrameFeatures? _halo(
    RawLampFrame frame,
    LampRoi roi,
    LampRoi other,
    FrameFeatures core,
  ) {
    final FrameFeatures ring = extractRing(
      frame,
      roi,
      config.ringScale,
      exclude: <LampRoi>[other],
    );
    // Кольцо, сжатое вычитанием в тонкую полоску, ничего не измеряет, но в
    // «пол» и в шум ложится как настоящее: на стенде рамка красной лампы стояла
    // у края кадра, её ореол терялся весь (rr=0.000), и канал молчал прогон.
    // Отсутствие честнее нуля: null не даёт ни подъёма, ни порога.
    if (core.sampleCount == 0 || ring.sampleCount * 4 < core.sampleCount) {
      return null;
    }
    return ring;
  }

  /// Признаки одной ROI в координатах самого кадра.
  ///
  /// Считаются `whiteFrac`, `redFrac`, контрольный [FrameFeatures.meanY] и —
  /// только когда включён режим [LampConfig.hsvReference] — HSV-доли
  /// [FrameFeatures.coolFrac]/[FrameFeatures.warmFrac]. На пиксель — два
  /// сравнения и одна ветка на каждый признак, поэтому размер ROI почти не
  /// влияет на частоту анализа.
  ///
  /// Когда включён [LampConfig.v6Spatial], к ним добавляются признаки
  /// спецификации v6 §2: медианы V и S, доля ярких пикселей, площадь и
  /// интенсивность ядра, число связных ядре-областей, доля ядра в центре,
  /// контраст центра с остальной ROI и гистограмма оттенка. Делается это в том
  /// же единственном проходе: второй проход по пикселям стоил бы половине
  /// частоты анализа.
  FrameFeatures extractRoi(RawLampFrame frame, LampRoi roi) =>
      _scan(frame, roi);

  /// Признаки кольца вокруг рамки: расширенная в [scale] раз область без самой
  /// рамки и без [exclude] (чужих ламп). Один лишний проход по пикселям — на
  /// пиксель два сравнения.
  ///
  /// Чужая лампа вычитается ВМЕСТЕ СО СВОИМ ОРЕОЛОМ, а не только колпаком:
  /// при ringScale 1.7 кольцо белой лампы дотягивается до x 0.559, пока
  /// красная рамка занимает 0.543…0.575 — то есть даже после вычитания
  /// прямоугольника колпака белое кольцо продолжало смотреть на красную лампу
  /// и записывало её вспышку в «белую» корзину.
  FrameFeatures extractRing(
    RawLampFrame frame,
    LampRoi roi,
    double scale, {
    List<LampRoi> exclude = const <LampRoi>[],
  }) {
    return _scan(
      frame,
      _grown(roi, scale),
      holes: <LampRoi>[roi, ...exclude.map((LampRoi r) => _grown(r, scale))],
    );
  }

  /// Та же рамка, расширенная в [scale] раз вокруг центра — её ореол.
  LampRoi _grown(LampRoi roi, double scale) {
    final double dx = roi.width * (scale - 1) / 2;
    final double dy = roi.height * (scale - 1) / 2;
    return LampRoi(
      left: roi.left - dx,
      top: roi.top - dy,
      width: roi.width * scale,
      height: roi.height * scale,
    ).normalized();
  }

  FrameFeatures _scan(
    RawLampFrame frame,
    LampRoi roi, {
    List<LampRoi> holes = const <LampRoi>[],
  }) {
    final _PixelSource source = switch (frame.format) {
      PixelFormatKind.yuv420 => _YuvSource(
        frame,
        fullRange: config.yuvFullRange,
      ),
      PixelFormatKind.bgra8888 => _BgraSource(frame),
      PixelFormatKind.unsupported => _EmptySource(),
    };

    final int left = (roi.left * frame.width).round();
    final int top = (roi.top * frame.height).round();
    final int right = (roi.right * frame.width).round();
    final int bottom = (roi.bottom * frame.height).round();

    // Пиксели внутри дырок в область не входят. Границы считаются один раз на
    // проход, а на каждой строке остаётся только сравнить x с двумя числами.
    final int holeCount = holes.length;
    final Int32List holeLeft = Int32List(holeCount);
    final Int32List holeTop = Int32List(holeCount);
    final Int32List holeRight = Int32List(holeCount);
    final Int32List holeBottom = Int32List(holeCount);
    for (int i = 0; i < holeCount; i++) {
      final LampRoi hole = holes[i];
      holeLeft[i] = (hole.left * frame.width).round();
      holeTop[i] = (hole.top * frame.height).round();
      holeRight[i] = (hole.right * frame.width).round();
      holeBottom[i] = (hole.bottom * frame.height).round();
    }
    final Int32List active = Int32List(holeCount);

    final _Sample sample = _Sample();
    final int step = config.subsampleStep;
    final double clipLuma = config.clipLuma;
    // HSV-отбор нужен только режиму [LampConfig.hsvReference]; в двух прежних
    // режимах эти доли не читаются, а шесть сравнений на пиксель из hot-цикла
    // никуда не деваются. Поэтому отбор включается здесь, а не считается всегда.
    final bool hsvOn = config.hsvReference;
    final double coolValueMin = config.hsvCoolValueMin;
    final double coolSatMax = config.hsvCoolSatMax;
    final double warmValueMin = config.hsvWarmValueMin;
    final double warmSatMin = config.hsvWarmSatMin;
    final double warmHueMax = config.hsvWarmHueMax;

    // Геометрия света (v6 §2, §5) считается только по флагу: он стоит ещё
    // нескольких сравнений и одной записи в маску на каждый опрошенный пиксель,
    // и прежние два способа решения этих чисел не спрашивают вовсе.
    final bool spatialOn = config.v6Spatial;
    final double brightValueMin = config.v6BrightValueMin;
    final double coreValueMin = config.v6CoreValueMin;
    final double hueSatMin = config.v6HueSatMin;
    final int hueBins = config.hueBins;
    // Центральное окно — доля СТОРОНЫ рамки: у колпака светящаяся поверхность
    // в середине, а по краю рамки лежит фон и ореол, на который и садится
    // отражение соседней лампы.
    final double span = config.v6CenterSpan.clamp(0.05, 1.0);
    final int centerLeft = (left + (right - left) * (1 - span) / 2).round();
    final int centerRight = (right - (right - left) * (1 - span) / 2).round();
    final int centerTop = (top + (bottom - top) * (1 - span) / 2).round();
    final int centerBottom = (bottom - (bottom - top) * (1 - span) / 2).round();
    // Сетка маски ядра идёт по тому же подвыбору, но с укрупнением, если
    // рамки велики: иначе связные области считались бы по памяти, а не по
    // геометрии.
    int gridStep = step;
    if (spatialOn) {
      while (gridStep < step * 64 &&
          ((right - left) / gridStep).ceil() *
                  ((bottom - top) / gridStep).ceil() >
              _maxCoreCells) {
        gridStep += step;
      }
    }
    final int gridW = spatialOn
        ? math.max(1, ((right - left) / gridStep).ceil())
        : 1;
    final int gridH = spatialOn
        ? math.max(1, ((bottom - top) / gridStep).ceil())
        : 1;
    final Uint8List coreMask = spatialOn ? _maskAt(gridW * gridH) : _emptyMask;

    double sumY = 0;
    double sumY2 = 0;
    int count = 0;
    int whiteCount = 0;
    int redCount = 0;
    int coolCount = 0;
    int warmCount = 0;
    int clipCount = 0;
    // Гистограмма яркости по всей области: из неё берутся процентиль и
    // разброс. Максимум одного пикселя как сигнал не годится — это блик или
    // шум квантования, а верх распределения показывает засвеченную площадь.
    final Int32List lumaHist = Int32List(256);
    // Те же счётчики по V и S: медианы v6 §2 берутся из гистограммы, а не из
    // сортировки подвыборки.
    final Int32List histV = spatialOn ? _histAt(_histVSlot, 256) : _emptyHist;
    final Int32List histS = spatialOn ? _histAt(_histSSlot, 64) : _emptyHist;
    final Int32List histHue = spatialOn
        ? _histAt(_histHueSlot, hueBins)
        : _emptyHist;
    int brightCount = 0;
    int coreCount = 0;
    int coreCenterCount = 0;
    int centerCount = 0;
    int restCount = 0;
    int satCount = 0;
    double coreSumV = 0;
    double centerSumV = 0;
    double restSumV = 0;

    for (int y = top; y < bottom; y += step) {
      if (y < 0) {
        continue;
      }
      if (y >= frame.height) {
        break;
      }
      int activeCount = 0;
      for (int i = 0; i < holeCount; i++) {
        if (y >= holeTop[i] && y < holeBottom[i]) {
          active[activeCount++] = i;
        }
      }
      for (int x = left; x < right; x += step) {
        if (x < 0) {
          continue;
        }
        if (x >= frame.width) {
          break;
        }
        bool inHole = false;
        for (int i = 0; i < activeCount; i++) {
          final int h = active[i];
          if (x >= holeLeft[h] && x < holeRight[h]) {
            inHole = true;
            break;
          }
        }
        if (inHole) {
          continue;
        }
        source.read(x, y, sample);
        count++;
        sumY += sample.y;
        sumY2 += sample.y * sample.y;
        lumaHist[sample.y.clamp(0.0, 255.0).round()]++;
        if (sample.y >= clipLuma) {
          clipCount++;
        }
        // «Настоящий белый»: все три канала яркие. Баланса R≈G≈B мало —
        // чёрная стена тоже сбалансирована, поэтому порог по минимальному
        // каналу.
        final double minChannel = sample.r < sample.g
            ? (sample.r < sample.b ? sample.r : sample.b)
            : (sample.g < sample.b ? sample.g : sample.b);
        if (minChannel >= config.whiteMinChannel) {
          whiteCount++;
        }
        // «Настоящий красный»: R заметно выше обоих остальных И он яркий —
        // иначе в признак попадают тёмно-бордовые тени и коричневое дерево.
        if (sample.r >= config.redMinValue &&
            sample.r - (sample.g > sample.b ? sample.g : sample.b) >=
                config.redMargin) {
          redCount++;
        }
        if (hsvOn || spatialOn) {
          // Дальнейшие проверки — это HSV без единого деления. Обозначения:
          // `mx` = V (0..255), `d` = mx − mn, тогда S = d / mx, а оттенок при
          // mx == r равен 60·(g − b)/d со знаком. Умножение на 255 держит
          // сравнение в целочисленном масштабе, как в `tools/hsv_probe.py`.
          final double maxChannel = sample.r > sample.g
              ? (sample.r > sample.b ? sample.r : sample.b)
              : (sample.g > sample.b ? sample.g : sample.b);
          final double delta = maxChannel - minChannel;
          if (hsvOn) {
            // «Белый свет»: ярко и почти без оттенка. Насыщенность d/mx мала,
            // поэтому красная лампа в этот отбор не попадает, а пересвеченный
            // колпак белой — попадает почти весь.
            if (maxChannel >= coolValueMin &&
                delta * 255 <= coolSatMax * maxChannel) {
              coolCount++;
            }
            // «Красный свет»: mx == r (иначе оттенка около нуля нет), оттенок не
            // дальше warmHueMax градусов от нуля, то есть |g − b| ≤ (H/60)·d, и
            // он достаточно ярок и насыщен — иначе это коричневое дерево стола.
            if (maxChannel == sample.r &&
                maxChannel >= warmValueMin &&
                delta * 255 >= warmSatMin * maxChannel &&
                (sample.g - sample.b).abs() * 60 <= warmHueMax * delta) {
              warmCount++;
            }
          }
          if (spatialOn) {
            final bool inCenter =
                x >= centerLeft &&
                x < centerRight &&
                y >= centerTop &&
                y < centerBottom;
            histV[maxChannel.clamp(0.0, 255.0).round()]++;
            histS[
                maxChannel > 0
                    ? (delta * 64 / maxChannel).round().clamp(0, 63)
                    : 0]
              ++;
            if (maxChannel >= brightValueMin) {
              brightCount++;
            }
            if (inCenter) {
              centerCount++;
              centerSumV += maxChannel;
            } else {
              restCount++;
              restSumV += maxChannel;
            }
            if (maxChannel >= coreValueMin) {
              coreCount++;
              coreSumV += maxChannel;
              if (inCenter) {
                coreCenterCount++;
              }
              final int gx = (x - left) ~/ gridStep;
              final int gy = (y - top) ~/ gridStep;
              if (gx >= 0 && gx < gridW && gy >= 0 && gy < gridH) {
                coreMask[gy * gridW + gx] = 1;
              }
            }
            // Оттенок считается единственным делением в цикле и только для
            // насыщенных пикселей: их в тёмной части кадра почти нет, а без
            // корзин красный на границе 0°/360° сложился бы в средний зелёный.
            if (maxChannel > 0 && delta * 255 >= hueSatMin * maxChannel) {
              satCount++;
              histHue[
                  _hueBin(
                    sample.r,
                    sample.g,
                    sample.b,
                    maxChannel,
                    delta,
                    hueBins,
                  )]++;
            }
          }
        }
      }
    }

    if (count == 0) {
      return FrameFeatures.zero;
    }

    final double mean = sumY / count;
    // Дисперсия считается как E[Y²] − (E[Y])² и может дать малое отрицательное
    // число из-за округлений на ровной области: наружу ему ходить нельзя.
    final double variance = (sumY2 / count - mean * mean).clamp(0.0, 65025.0);

    // Числа геометрии света (v6 §2). Всё, кроме медиан, считается по ядру:
    // там, где яркости нет, ни площади, ни связности, ни центра обсуждать нечего,
    // и ноль в этих полях честнее выдуманного значения.
    double medianV = 0;
    double medianS = 0;
    double coreIntensity = 0;
    double coreCenterFrac = 0;
    double centerContrast = 0;
    double coreRegions = 0;
    Float64List? hueHist;
    if (spatialOn) {
      medianV = _percentile(histV, count, 0.5);
      // Шкала S — 64 корзин по 4 единицы, обратно в 0..255.
      medianS = _percentile(histS, count, 0.5) * 4.0;
      if (coreCount > 0) {
        coreIntensity = coreSumV / coreCount;
        coreCenterFrac = coreCenterCount / coreCount;
        coreRegions = _countRegions(
          coreMask,
          gridW,
          gridH,
          _parentAt(gridW * gridH),
        ).toDouble();
      }
      if (centerCount > 0 && restCount > 0) {
        centerContrast =
            (centerSumV / centerCount - restSumV / restCount) / 255.0;
      }
      if (satCount > 0) {
        hueHist = Float64List(hueBins);
        for (int i = 0; i < hueBins; i++) {
          hueHist[i] = histHue[i] / satCount;
        }
      }
    }

    return FrameFeatures(
      meanY: mean,
      sampleCount: count,
      whiteFrac: whiteCount / count,
      redFrac: redCount / count,
      coolFrac: coolCount / count,
      warmFrac: warmCount / count,
      p90Luma: _percentile(lumaHist, count, config.lumaPercentile),
      lumaStdDev: math.sqrt(variance),
      clippedRatio: clipCount / count,
      medianV: medianV,
      medianS: medianS,
      brightFrac: brightCount / count,
      coreAreaFrac: coreCount / count,
      coreIntensity: coreIntensity,
      coreRegions: coreRegions,
      coreCenterFrac: coreCenterFrac,
      centerContrast: centerContrast,
      hueHist: hueHist,
    );
  }

  /// Корзина оттенка 0..N−1 по стандартной формуле HSV. Вокруг нуля красный
  /// занимает и начало, и конец шкалы — именно поэтому признаком служит
  /// гистограмма, а не среднее: среднее по такому распределению равно зелёному.
  static int _hueBin(
    double r,
    double g,
    double b,
    double mx,
    double delta,
    int bins,
  ) {
    double degrees;
    if (mx == r) {
      degrees = 60 * (g - b) / delta;
    } else if (mx == g) {
      degrees = 120 + 60 * (b - r) / delta;
    } else {
      degrees = 240 + 60 * (r - g) / delta;
    }
    degrees %= 360;
    if (degrees < 0) {
      degrees += 360;
    }
    return (degrees * bins / 360).floor().clamp(0, bins - 1);
  }

  /// Число 4-связных областей в маске ядра — «connected bright regions» v6 §2.
  ///
  /// Два прохода с union-find по сетке подвыборки, без рекурсии и без alloc на
  /// клетку: одна маска и один массив предков, оба переиспользуются. Связность
  /// по сетке подвыборки, а не по пикселям, — честное упрощение: шаг
  /// [LampConfig.subsampleStep] меньше размера ядра настоящей лампы, поэтому
  /// разорвать одно включение на две клетки он не может.
  static int _countRegions(
    Uint8List mask,
    int w,
    int h,
    Int32List parent,
  ) {
    final int n = w * h;
    for (int i = 0; i < n; i++) {
      parent[i] = i;
    }
    for (int y = 0; y < h; y++) {
      final int row = y * w;
      for (int x = 0; x < w; x++) {
        final int i = row + x;
        if (mask[i] == 0) {
          continue;
        }
        if (x > 0 && mask[i - 1] != 0) {
          _union(parent, i, i - 1);
        }
        if (y > 0 && mask[i - w] != 0) {
          _union(parent, i, i - w);
        }
      }
    }
    int regions = 0;
    for (int i = 0; i < n; i++) {
      if (mask[i] != 0 && _find(parent, i) == i) {
        regions++;
      }
    }
    return regions;
  }

  static void _union(Int32List parent, int a, int b) {
    final int ra = _find(parent, a);
    final int rb = _find(parent, b);
    if (ra != rb) {
      parent[rb] = ra;
    }
  }

  static int _find(Int32List parent, int i) {
    int root = i;
    while (parent[root] != root) {
      root = parent[root];
    }
    while (parent[i] != root) {
      final int next = parent[i];
      parent[i] = root;
      i = next;
    }
    return root;
  }

  /// Маска ядра и предки union-find живут в поле: на каждый кадр по две
  /// аллокации размером с сетку ROI — это то, чего hot-цикл не переживёт при
  /// высокой частоте анализа.
  Uint8List _maskAt(int cells) {
    if (_mask.length < cells) {
      _mask = Uint8List(cells);
    }
    _mask.fillRange(0, cells, 0);
    return _mask;
  }

  Int32List _parentAt(int cells) {
    if (_parent.length < cells) {
      _parent = Int32List(cells);
    }
    return _parent;
  }

  /// Гистограммы признаков: буфер переиспользуется, но обязан начаться нулями,
  /// иначе счётчик прошлого кадра прибавится к этому.
  Int32List _histAt(int slot, int length) {
    final Int32List hist = _hists[slot];
    if (hist.length < length) {
      final Int32List grown = Int32List(length);
      _hists[slot] = grown;
      return grown;
    }
    hist.fillRange(0, length, 0);
    return hist;
  }

  /// Значение яркости, ниже которого лежит `fraction` опрошенных пикселей.
  /// По гистограмме, а не по сортировке: сортировка подвыборки стоила бы
  /// N log N на каждый кадр, а гистограмма — 256 сложений в конце прохода.
  static double _percentile(Int32List histogram, int count, double fraction) {
    final int target = (count * fraction.clamp(0.0, 1.0)).ceil();
    int seen = 0;
    for (int bin = 0; bin < histogram.length; bin++) {
      seen += histogram[bin];
      if (seen >= target) {
        return bin.toDouble();
      }
    }
    return 255;
  }

  /// Кадр целиком как RGB (по 3 байта на пиксель, строки подряд). Нужен только
  /// для отладки: по файлу видно реальную ориентацию кадра с сенсора и куда
  /// попадают ROI. В детекции не участвует.
  Uint8List toRgb(RawLampFrame frame) {
    final _PixelSource source = switch (frame.format) {
      PixelFormatKind.yuv420 => _YuvSource(
        frame,
        fullRange: config.yuvFullRange,
      ),
      PixelFormatKind.bgra8888 => _BgraSource(frame),
      PixelFormatKind.unsupported => _EmptySource(),
    };
    final int w = frame.width;
    final int h = frame.height;
    final Uint8List out = Uint8List(w * h * 3);
    final _Sample sample = _Sample();
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        source.read(x, y, sample);
        final int o = (y * w + x) * 3;
        out[o] = sample.r.clamp(0.0, 255.0).round();
        out[o + 1] = sample.g.clamp(0.0, 255.0).round();
        out[o + 2] = sample.b.clamp(0.0, 255.0).round();
      }
    }
    return out;
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
