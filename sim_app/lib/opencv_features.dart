import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:lamp_detection/lamp_detection.dart'
    show
        FrameMapping,
        LampConfig,
        LampRoi,
        PixelFormatKind,
        RawLampFrame,
        RoiLayout;
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Измерение одной области кадра, снятое OpenCV.
///
/// Набор слов совпадает с `FrameFeatures` рабочего экстрактора нарочно: у
/// сравнения смысл только тогда, когда оба способа отвечают на ОДИН и ТОТ ЖЕ
/// вопрос. Там, где OpenCV ответа не даёт (например, доли цветных пикселей в
/// YUV-кадре без цветности), поле остаётся null: отсутствие честнее нуля,
/// иначе сравнение показало бы расхождение там, где его просто нет.
class OpenCvFeatureMeasure {
  const OpenCvFeatureMeasure({
    required this.pixelCount,
    required this.meanY,
    required this.lumaStdDev,
    required this.p90Luma,
    required this.clippedRatio,
    this.whiteFrac,
    this.redFrac,
  });

  /// Ничего не измерено. Отличие от «измерен ноль» важное: ноль — это ответ,
  /// а это — его отсутствие.
  static const OpenCvFeatureMeasure empty = OpenCvFeatureMeasure(
    pixelCount: 0,
    meanY: 0,
    lumaStdDev: 0,
    p90Luma: 0,
    clippedRatio: 0,
  );

  /// Сколько пикселей реально попало в область.
  final int pixelCount;

  /// Средняя яркость (0..255).
  final double meanY;

  /// СКО яркости внутри области — то же, что `lumaStdDev`.
  final double lumaStdDev;

  /// Верхний процентиль яркости — то же, что `p90Luma`.
  final double p90Luma;

  /// Доля пикселей на клиппинге — то же, что `clippedRatio`.
  final double clippedRatio;

  /// Доля «настоящего белого»; null, если цветов мерить нечем.
  final double? whiteFrac;

  /// Доля «настоящего красного»; null, если цветов мерить нечем.
  final double? redFrac;

  /// Контраст области: насколько верх распределения выше среднего. Рабочий
  /// экстрактор этого числа не отдаёт — оно здесь ровно для того, чтобы видеть
  /// «мало ярко» и «много средне» как разные события.
  double get contrast => p90Luma - meanY;

  @override
  String toString() =>
      'сред ${meanY.toStringAsFixed(1)} σ ${lumaStdDev.toStringAsFixed(1)} '
      'p90 ${p90Luma.toStringAsFixed(0)} '
      'кл ${(clippedRatio * 100).toStringAsFixed(1)}%'
      '${whiteFrac == null ? '' : ' б${(whiteFrac! * 100).toStringAsFixed(1)}% '
          'к${(redFrac! * 100).toStringAsFixed(1)}%'} '
      '($pixelCount px)';
}

/// Результат измерения одного кадра независимым способом.
class OpenCvFrameMeasure {
  const OpenCvFrameMeasure({
    required this.frameWidth,
    required this.frameHeight,
    required this.blurKernel,
    required this.frame,
    required this.whiteCore,
    required this.redCore,
    this.whiteRing,
    this.redRing,
    this.motionMean = 0,
    this.notes = const <String>[],
  });

  final int frameWidth;
  final int frameHeight;

  /// Размер гауссова ядра, которым кадр был сглажен.
  final int blurKernel;

  /// Всё поле кадра — по нему видно, что сцена посветлела целиком.
  final OpenCvFeatureMeasure frame;

  final OpenCvFeatureMeasure whiteCore;
  final OpenCvFeatureMeasure redCore;

  /// Ореолы; null — если от кольца после вычитания колпаков остаться нечему.
  final OpenCvFeatureMeasure? whiteRing;
  final OpenCvFeatureMeasure? redRing;

  /// Средний |разница| с предыдущим сглаженным кадром: движение света.
  final double motionMean;

  /// Чем измеритель недоволен: неподходящий формат, несжатый ореол.
  final List<String> notes;

  /// Центр минус кольцо — насколько яркость колпака выше яркости его же
  /// ореола. Именно это отличает лампу от засветки всей сцены.
  double? get whiteCenterMinusRing =>
      whiteRing == null ? null : whiteCore.meanY - whiteRing!.meanY;

  double? get redCenterMinusRing =>
      redRing == null ? null : redCore.meanY - redRing!.meanY;
}

/// Второй измеритель света на OpenCV.
///
/// Делает ровно то, что требует инструкция: переводит кадр в оттенки серого,
/// сглаживает, смотрит, что изменилось с прошлого кадра, и по каждой зоне
/// считает среднее, СКО, верхний процентиль, долю пикселей на клиппинге и
/// доли белого/красного. Решений он не принимает — у него нет ни порогов, ни
/// состояний, ни права создать событие; всё это остаётся в основном
/// конвейере. Сравнение строится на его числах, а автомат работает по числам
/// рабочего экстрактора.
///
/// Геометрия зон берётся та же, чем решает рабочий конвейер ([config]), чтобы
/// расхождение могло возникнуть только из способа измерения, а не из того, что
/// «померили разные прямоугольники».
class OpenCvFeatureExtractor {
  OpenCvFeatureExtractor({
    required this.config,
    this.blurKernelSize = 5,
    this.blurSigma = 0,
    this.trackMotion = true,
    this.percentile,
  });

  /// Те же рамки, ореолы и пороги цвета, что у рабочего экстрактора.
  final LampConfig config;

  /// Нечётный размер гауссова ядра; меньше 3 = без сглажения.
  final int blurKernelSize;

  /// 0 = OpenCV сам берёт σ по размеру ядра.
  final double blurSigma;

  /// Мерить ли |разницу| с предыдущим кадром. Стоит одну ячейку памяти под
  /// прошлый кадр, поэтому в прогонах с очень большим кадром можно выключить.
  final bool trackMotion;

  /// Какой процентиль яркости снимать. По умолчанию — тот же `lumaPercentile`
  /// конфига, что берёт рабочий экстрактор: иначе сравнивали бы разные
  /// границы распределения, а не два способа измерения.
  final double? percentile;

  double get _percentile => percentile ?? config.lumaPercentile;

  cv.Mat? _previous;

  /// Измерить кадр. Null, если формата, который умеет OpenCV, в кадре нет.
  ///
  /// YUV420 берётся как есть: плоскость Y у камеры — те же оттенки серого, что
  /// получились бы из RGB, только без потерь на конверсии. Цветность в этой
  /// ветке не меряется: рабочий экстрактор восстанавливает RGB из U/V по своим
  /// формулам, и вторая реализация тех же формул сравнивала бы не способ, а
  /// две конверсии.
  OpenCvFrameMeasure? measure(
    RawLampFrame frame,
    RoiLayout roi, {
    FrameMapping mapping = FrameMapping.identity,
  }) {
    final List<String> notes = <String>[];
    final _Plane? plane = _toGray(frame, notes);
    if (plane == null) {
      return null;
    }
    final int width = plane.mat.cols;
    final int height = plane.mat.rows;
    final cv.Mat blurred = _blur(plane.mat);
    // Копия, которая переживёт этот вызов: прошлый кадр должен оставаться
    // валидным, пока измеряется следующий.
    final cv.Mat current = blurred.clone();
    final _Rects rects = _Rects();
    try {
      final double motion = _motion(current);
      final LampRoi white = mapping.toFrameRoi(roi.white);
      final LampRoi red = mapping.toFrameRoi(roi.red);
      final bool withRing = config.ringScale > 1;

      final OpenCvFeatureMeasure whiteCore = _measure(
        current,
        rects.rectOf(white, width, height),
        frame,
      );
      final OpenCvFeatureMeasure redCore =
          _measure(current, rects.rectOf(red, width, height), frame);

      OpenCvFeatureMeasure? halo(
        LampRoi own,
        LampRoi other,
        OpenCvFeatureMeasure core,
      ) {
        if (!withRing) {
          return null;
        }
        final List<cv.Rect> holes = <cv.Rect>[
          rects.rectOf(own, width, height),
          rects.rectOf(grownRoi(other, config.ringScale), width, height),
        ];
        final OpenCvFeatureMeasure ring = _measure(
          current,
          rects.rectOf(grownRoi(own, config.ringScale), width, height),
          frame,
          holes: holes,
        );
        // То же правило, что у рабочего экстрактора: сжатое вычитанием кольцо
        // не измеряет ничего, но в «пол» и в шум ложится как настоящее.
        if (core.pixelCount == 0 ||
            ring.pixelCount * 4 < core.pixelCount) {
          notes.add(
            'ореол ${own.center.dx.toStringAsFixed(2)} не измерен: '
            'после вычитания осталось ${ring.pixelCount} px '
            'на ${core.pixelCount} px колпака',
          );
          return null;
        }
        return ring;
      }

      return OpenCvFrameMeasure(
        frameWidth: width,
        frameHeight: height,
        blurKernel: blurKernelSize,
        frame: _measure(current, rects.whole(width, height), frame),
        whiteCore: whiteCore,
        redCore: redCore,
        whiteRing: halo(white, red, whiteCore),
        redRing: halo(red, white, redCore),
        motionMean: motion,
        notes: List<String>.unmodifiable(notes),
      );
    } finally {
      rects.dispose();
      current.dispose();
      if (!identical(blurred, plane.mat)) {
        blurred.dispose();
      }
      // Буфер пикселей живёт, пока жив Mat, собранный из него: освобождает
      // их вместе [_Plane], а не по отдельности.
      plane.dispose();
    }
  }

  /// Забыть прошлый кадр — например, при остановке прогона.
  void resetMotion() {
    _previous?.dispose();
    _previous = null;
  }

  /// Освобождает память прошлого кадра. Вызывать вместе с источником кадров.
  void dispose() => resetMotion();

  // ---------------------------------------------------------------------
  // Путь от байтов камеры до одного числа
  // ---------------------------------------------------------------------

  /// Оттенки серого из кадра вместе с буфером, который их держит.
  ///
  /// Строки должны идти подряд: Mat из чужой памяти с произвольным шагом этот
  /// вариант OpenCV не строит, а врать со шагом — значит измерить не то,
  /// поэтому несогласованный кадр отвергается, а не «чинится».
  _Plane? _toGray(RawLampFrame frame, List<String> notes) {
    switch (frame.format) {
      case PixelFormatKind.yuv420:
        final Uint8List? luma = frame.luma;
        if (luma == null) {
          notes.add('YUV420 без плоскости Y');
          return null;
        }
        final int stride = frame.lumaStride ?? frame.width;
        if (stride != frame.width) {
          notes.add('плоскость Y со stride $stride ≠ ${frame.width}');
          return null;
        }
        if (luma.length < stride * frame.height) {
          notes.add('плоскость Y короче кадра');
          return null;
        }
        return _Plane.wrap(luma, frame.height, frame.width, cv.MatType.CV_8UC1);
      case PixelFormatKind.bgra8888:
        final Uint8List? pixels = frame.pixels;
        if (pixels == null) {
          notes.add('BGRA без пикселей');
          return null;
        }
        final int stride = frame.rowStride ?? frame.width * 4;
        if (stride != frame.width * 4 || (frame.pixelStride ?? 4) != 4) {
          notes.add('упаковка BGRA со stride $stride ≠ ${frame.width * 4}');
          return null;
        }
        if (pixels.length < stride * frame.height) {
          notes.add('буфер пикселей короче кадра');
          return null;
        }
        final _Plane packed = _Plane.wrap(
          pixels,
          frame.height,
          frame.width,
          cv.MatType.CV_8UC4,
        );
        final cv.Mat gray;
        try {
          gray = cv.cvtColor(packed.mat, cv.COLOR_BGRA2GRAY);
        } on Object {
          packed.dispose();
          rethrow;
        }
        return _Plane.gray(gray, packed);
      case PixelFormatKind.unsupported:
        notes.add('формат кадра не поддерживается');
        return null;
    }
  }

  cv.Mat _blur(cv.Mat gray) {
    if (blurKernelSize < 3) {
      return gray;
    }
    final int k = blurKernelSize | 1;
    return cv.gaussianBlur(gray, (k, k), blurSigma);
  }

  /// Средний модуль разницы с прошлым кадром. Принимает уже копию текущего,
  /// чтобы в `_previous` не остался Mat, живший в памяти этого вызова.
  double _motion(cv.Mat currentCopy) {
    if (!trackMotion) {
      return 0;
    }
    final cv.Mat? previous = _previous;
    _previous = currentCopy.clone();
    if (previous == null) {
      return 0;
    }
    try {
      final cv.Mat diff = cv.absDiff(currentCopy, previous);
      try {
        final (cv.Scalar mean, cv.Scalar sd) = cv.meanStdDev(diff);
        final double value = mean.val1;
        mean.dispose();
        sd.dispose();
        return value;
      } finally {
        diff.dispose();
      }
    } on Object {
      // Источник сменил разрешение: кадры разного размера сравнивать нельзя,
      // и это не ошибка прогона — просто первое число после смены кадра.
      return 0;
    } finally {
      previous.dispose();
    }
  }

  /// Все числа одной области: маска → статистика → гистограмма → доли цвета.
  ///
  /// Прямоугольник принадлежит [_Rects] вызывающего и здесь не освобождается.
  OpenCvFeatureMeasure _measure(
    cv.Mat gray,
    cv.Rect rect,
    RawLampFrame source, {
    List<cv.Rect> holes = const <cv.Rect>[],
  }) {
    if (rect.width <= 0 || rect.height <= 0) {
      return OpenCvFeatureMeasure.empty;
    }
    final cv.Mat mask = _regionMask(rect, holes);
    final cv.Mat sub = cv.Mat.fromMat(gray, roi: rect);
    try {
      final int pixels = cv.countNonZero(mask);
      if (pixels == 0) {
        return OpenCvFeatureMeasure.empty;
      }
      final (cv.Scalar mean, cv.Scalar std) = cv.meanStdDev(sub, mask: mask);
      final _Hist hist = _histogram(sub, mask);
      final (double? whiteFrac, double? redFrac) =
          _colorFractions(source, rect, holes);
      final OpenCvFeatureMeasure result = OpenCvFeatureMeasure(
        pixelCount: pixels,
        meanY: mean.val1,
        lumaStdDev: std.val1,
        p90Luma: hist.percentile(_percentile),
        clippedRatio: hist.atLeast(config.clipLuma.round()) / pixels,
        whiteFrac: whiteFrac,
        redFrac: redFrac,
      );
      mean.dispose();
      std.dispose();
      return result;
    } finally {
      mask.dispose();
      sub.dispose();
    }
  }

  /// Маска области с вырезанными дырами: 255 = пиксель входит, 0 = нет.
  ///
  /// Прямоугольник области целиком закрашивается 255 и только потом режется:
  /// маска, созданная нулями, давала бы «в области нет ни одного пикселя», и
  /// вся статистика области съехала бы в ноль молча.
  ///
  /// Дыры режутся в координатах самой области — маска меньше кадра на её
  /// сдвиг, и прямоугольник в чужих координатах вырезал бы не то.
  cv.Mat _regionMask(cv.Rect rect, List<cv.Rect> holes) {
    final cv.Scalar inside = cv.Scalar.all(255);
    final cv.Scalar outside = cv.Scalar.all(0);
    final cv.Mat mask = cv.Mat.fromScalar(
      rect.height,
      rect.width,
      cv.MatType.CV_8UC1,
      inside,
    );
    final List<cv.Rect> cuts = <cv.Rect>[];
    for (final cv.Rect hole in holes) {
      final cv.Rect? clipped = _clip(hole, rect);
      if (clipped != null) {
        cuts.add(clipped);
      }
    }
    try {
      for (final cv.Rect cut in cuts) {
        cv.rectangle(mask, cut, outside, thickness: -1);
      }
    } finally {
      for (final cv.Rect cut in cuts) {
        cut.dispose();
      }
      outside.dispose();
      inside.dispose();
    }
    return mask;
  }

  /// Гистограмма яркости области по 256 корзинам. Из неё берутся и процентиль,
  /// и доля на клиппинге: пороги-скаляры в `inRange` этот вариант OpenCV не
  /// принимает, а гистограмма нужна та же, что у рабочего экстрактора, — иначе
  /// сравнивали бы две разные статистики.
  _Hist _histogram(cv.Mat src, cv.Mat mask) {
    final cv.VecMat mats = cv.VecMat();
    final cv.VecI32 channels = cv.VecI32(1, 0);
    final cv.VecI32 histSize = cv.VecI32(1, 256);
    final cv.VecF32 ranges = cv.VecF32.fromList(<double>[0, 256]);
    final cv.Mat hist = cv.Mat.zeros(1, 256, cv.MatType.CV_32FC1);
    try {
      mats.add(src);
      cv.calcHist(mats, channels, mask, histSize, ranges, hist: hist);
      final List<double> bins = hist
          .ptrAt<ffi.Float>(0)
          .asTypedList(256)
          .toList(growable: false);
      return _Hist(bins);
    } finally {
      hist.dispose();
      ranges.dispose();
      histSize.dispose();
      channels.dispose();
      mats.dispose();
    }
  }

  /// Доли белого и красного по тем же критериям, что у рабочего экстрактора,
  /// но по всем пикселям области, а не по подвыборке: это независимый способ,
  /// и он обязан считать ту же формулу, а не ту же редкую выборку.
  ///
  /// Берётся из исходных байтов кадра: в YUV-кадре цветности может не быть, и
  /// тогда ответ «не измеряли» честнее ответа «ноль».
  (double?, double?) _colorFractions(
    RawLampFrame frame,
    cv.Rect rect,
    List<cv.Rect> holes,
  ) {
    if (frame.format != PixelFormatKind.bgra8888) {
      return (null, null);
    }
    final Uint8List? bytes = frame.pixels;
    if (bytes == null) {
      return (null, null);
    }
    final int rowStride = frame.rowStride ?? frame.width * 4;
    final int pixelStride = frame.pixelStride ?? 4;
    if (pixelStride != 4) {
      return (null, null);
    }
    int white = 0;
    int red = 0;
    int counted = 0;
    for (int y = rect.y; y < rect.y + rect.height; y++) {
      if (y < 0 || y >= frame.height) {
        continue;
      }
      for (int x = rect.x; x < rect.x + rect.width; x++) {
        if (x < 0 || x >= frame.width) {
          continue;
        }
        if (_inAnyHole(x, y, holes)) {
          continue;
        }
        final int i = y * rowStride + x * pixelStride;
        if (i + 3 >= bytes.length) {
          continue;
        }
        final int b = bytes[i];
        final int g = bytes[i + 1];
        final int r = bytes[i + 2];
        counted++;
        if (math.min(math.min(r, g), b) >= config.whiteMinChannel) {
          white++;
        }
        if (r >= config.redMinValue && r - math.max(g, b) >= config.redMargin) {
          red++;
        }
      }
    }
    if (counted == 0) {
      return (null, null);
    }
    return (white / counted, red / counted);
  }

  bool _inAnyHole(int x, int y, List<cv.Rect> holes) {
    for (final cv.Rect h in holes) {
      if (x >= h.x && x < h.x + h.width && y >= h.y && y < h.y + h.height) {
        return true;
      }
    }
    return false;
  }

  /// Пересечение дыры с областью в координатах области; null — если снаружи.
  cv.Rect? _clip(cv.Rect hole, cv.Rect rect) {
    final int left = math.max(hole.x, rect.x);
    final int top = math.max(hole.y, rect.y);
    final int right = math.min(hole.x + hole.width, rect.x + rect.width);
    final int bottom = math.min(hole.y + hole.height, rect.y + rect.height);
    if (right <= left || bottom <= top) {
      return null;
    }
    return cv.Rect(left - rect.x, top - rect.y, right - left, bottom - top);
  }
}

/// Прямоугольники зон одного измерения: все созданные здесь освобождаются
/// одним вызовом, потому что каждый из них — нативная память.
class _Rects {
  final List<cv.Rect> _owned = <cv.Rect>[];

  /// Нормализованная зона в пиксельных границах — те же `round()`, что в
  /// рабочем проходе, чтобы границы зон не разъехались на пиксель.
  cv.Rect rectOf(LampRoi roi, int width, int height) {
    final int left = (roi.left * width).round().clamp(0, width);
    final int top = (roi.top * height).round().clamp(0, height);
    final int right = (roi.right * width).round().clamp(0, width);
    final int bottom = (roi.bottom * height).round().clamp(0, height);
    final cv.Rect rect = cv.Rect(
      left,
      top,
      math.max(0, right - left),
      math.max(0, bottom - top),
    );
    _owned.add(rect);
    return rect;
  }

  /// Весь кадр — для измерения «сцена посветлела целиком».
  cv.Rect whole(int width, int height) {
    final cv.Rect rect = cv.Rect(0, 0, width, height);
    _owned.add(rect);
    return rect;
  }

  void dispose() {
    for (final cv.Rect rect in _owned) {
      rect.dispose();
    }
    _owned.clear();
  }
}

/// Рамка, расширенная в [scale] раз вокруг центра — её ореол.
///
/// Тот же расчёт, что в рабочем экстракторе: сравнение двух способов имеет
/// смысл, только если зоны у них общие.
LampRoi grownRoi(LampRoi roi, double scale) {
  final double dx = roi.width * (scale - 1) / 2;
  final double dy = roi.height * (scale - 1) / 2;
  return LampRoi(
    left: roi.left - dx,
    top: roi.top - dy,
    width: roi.width * scale,
    height: roi.height * scale,
  ).normalized();
}

/// Оттенки серого одного кадра и нативный буфер, который их держит.
///
/// `Mat.fromBuffer` данных не копирует, поэтому буфер обязан жить дольше Mat:
/// порядок освобождения — ровно поэтому они упакованы в один класс.
class _Plane {
  _Plane._(
    this.mat, {
    this.keep,
    this.buffer,
    bool ownsBuffer = false,
  }) : _ownsBuffer = ownsBuffer;

  /// Серое изображение кадра — то, чем меряем.
  cv.Mat mat;

  /// Измерение, чью память обязан пережить этот кадр: упакованный BGRA до
  /// превращения в оттенки серого.
  _Plane? keep;

  /// Буфер, из которого собран Mat. `Mat.fromBuffer` данных не копирует,
  /// поэтому буфер обязан жить дольше Mat. У Mat'ов, память которым выделил
  /// сам OpenCV, буфера нет: чужую память освобождать нельзя.
  final ffi.Pointer<ffi.Void>? buffer;
  final bool _ownsBuffer;

  /// Серое изображение, собранное из байтов кадра.
  ///
  /// Копия, а не чужая память: источник кадров переиспользует буфер, и
  /// смотреть в него напрямую было бы гонкой.
  factory _Plane.wrap(Uint8List bytes, int rows, int cols, cv.MatType type) {
    final ffi.Pointer<ffi.Uint8> buffer = calloc<ffi.Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setRange(0, bytes.length, bytes);
    return _Plane._(
      cv.Mat.fromBuffer(rows, cols, type, buffer.cast()),
      buffer: buffer.cast(),
      ownsBuffer: true,
    );
  }

  /// Оттенки серого, которые выделил сам OpenCV, плюс упакованный кадр, без
  /// которого они бессмысленны.
  factory _Plane.gray(cv.Mat gray, _Plane source) =>
      _Plane._(gray, keep: source);

  void dispose() {
    mat.dispose();
    keep?.dispose();
    // Буфер освобождаем последним: до этой строки на него ещё смотрел Mat.
    final ffi.Pointer<ffi.Void>? owned = buffer;
    if (_ownsBuffer && owned != null) {
      calloc.free(owned);
    }
  }
}

/// Гистограмма яркости области в 256 корзинах.
class _Hist {
  _Hist(this.bins);

  final List<double> bins;

  int get total => bins.fold<int>(0, (int sum, double v) => sum + v.round());

  /// Значение яркости, ниже которого лежит [fraction] пикселей — та же
  /// формула, что у рабочего экстрактора (ceil от доли, поиск по корзинам).
  double percentile(double fraction) {
    final int count = total;
    if (count == 0) {
      return 0;
    }
    final int target = (count * fraction.clamp(0.0, 1.0)).ceil();
    int seen = 0;
    for (int bin = 0; bin < bins.length; bin++) {
      seen += bins[bin].round();
      if (seen >= target) {
        return bin.toDouble();
      }
    }
    return 255;
  }

  /// Сколько пикселей яркости [value] и выше — то есть на клиппинге.
  double atLeast(int value) {
    double sum = 0;
    for (int bin = value.clamp(0, bins.length); bin < bins.length; bin++) {
      sum += bins[bin];
    }
    return sum;
  }
}
