import 'package:lamp_detection/lamp_detection.dart';

import 'opencv_features.dart';

/// Один кадр, измеренный двумя способами сразу.
///
/// Пара живёт ровно для того, чтобы сравнивать числа, а не решения: у
/// рабочего экстрактора есть решение автомата, у OpenCV — только измерения.
class ShadowPair {
  const ShadowPair({
    required this.index,
    required this.working,
    required this.shadow,
    required this.whiteDecision,
    required this.redDecision,
    this.shadowFailure,
  });

  /// Номер обработанного кадра.
  final int index;

  /// Что посчитал конвейер (белый колпак, красный колпак, ореолы).
  final LampFrame working;

  /// Что посчитал OpenCV на тех же пикселях; null — если кадр ему не по зубам.
  final OpenCvFrameMeasure? shadow;

  /// Решение автомата по этому кадру — чтобы видеть, что тень на него не
  /// повлияла.
  final bool whiteDecision;
  final bool redDecision;

  /// Текст ошибки самого измерителя. Он не должен ронять прогон, но молчать
  /// тем более не должен.
  final String? shadowFailure;
}

/// Теневой измеритель на OpenCV.
///
/// Подключается единственным возможным способом — как [ShadowProbe] к
/// [DetectionSession]: получает сырой кадр, те же зоны и уже принятое
/// решение, и обязан остаться наблюдателем. У него нет прав ни на порог, ни на
/// событие; единственное, что он отдаёт наружу, — числа для сравнения.
class OpenCvShadowInstrument {
  OpenCvShadowInstrument({
    required this.extractor,
    this.workingExtractor,
    this.maxPairs = 600,
    this.onReport,
  });

  /// Независимый измеритель.
  final OpenCvFeatureExtractor extractor;

  /// Второй проход рабочим экстрактором по тем же пикселям — затем, чтобы
  /// рядом с числами OpenCV в одном прогоне лежали числа того же кадра, а не
  /// пересказ решения. Обычно это тот же экземпляр, чем пользуется сессия, но
  /// можно передать и null: тогда в отчёте лежат признаки кадра из
  /// `ShadowInput`.
  final FeatureExtractor? workingExtractor;

  /// Сколько кадров копить в памяти. Дальше — только печать отчёта, иначе
  /// многочасовой прогон съел бы RAM.
  final int maxPairs;

  /// Куда печатать отчёт по достижении [maxPairs].
  final void Function(String report)? onReport;

  final List<ShadowPair> _pairs = <ShadowPair>[];
  int _seen = 0;
  int _failures = 0;

  /// Сколько кадров не влезло в память после [maxPairs]. Числа от этого не
  /// меняются: просто пора печатать отчёт.
  int _overflow = 0;
  bool _flushed = false;

  /// Все собранные пары — для теста, который сверяет числа сам.
  List<ShadowPair> get pairs => List<ShadowPair>.unmodifiable(_pairs);

  int get seen => _seen;
  int get failures => _failures;

  /// Что автомат решил по последнему кадру: сумма событий, чтобы прогон мог
  /// проверить, что тень их не изменила.
  int get events => _pairs.where((ShadowPair p) => p.whiteDecision || p.redDecision).length;

  /// Единственная точка входа для сессии.
  ///
  /// Вызывается ПОСЛЕ того, как события уже приняты и отправлены, поэтому
  /// повлиять на автомат физически нечем. Само тело не бросает: ошибка
  /// измерителя превращается в строку в отчёте, а не в падение прогона.
  void observe(ShadowInput input) {
    OpenCvFrameMeasure? measure;
    String? failure;
    try {
      measure = extractor.measure(input.raw, input.roi, mapping: input.mapping);
    } on Object catch (e) {
      failure = e.toString();
      _failures++;
    }
    _record(
      working: _recompute(input),
      shadow: measure,
      whiteDecision: input.evaluation?.whiteOn ?? false,
      redDecision: input.evaluation?.redOn ?? false,
      shadowFailure: failure,
    );
  }

  /// Измерить кадр напрямую, без сессии и без автомата: только фотометрия.
  ///
  /// Решений здесь взяться неоткуда — `whiteDecision` и `redDecision` всегда
  /// false, и отчёт честно показывает пустую колонку решения.
  void addDirect(
    RawLampFrame raw,
    RoiLayout roi, [
    FrameMapping mapping = FrameMapping.identity,
  ]) {
    OpenCvFrameMeasure? measure;
    String? failure;
    try {
      measure = extractor.measure(raw, roi, mapping: mapping);
    } on Object catch (e) {
      failure = e.toString();
      _failures++;
    }
    final FeatureExtractor? working = workingExtractor;
    _record(
      working: working == null
          ? LampFrame(
              timestamp: raw.receivedAt,
              white: FrameFeatures.zero,
              red: FrameFeatures.zero,
            )
          : working.extract(raw, roi, mapping),
      shadow: measure,
      whiteDecision: false,
      redDecision: false,
      shadowFailure: failure,
    );
  }

  void _record({
    required LampFrame working,
    required OpenCvFrameMeasure? shadow,
    required bool whiteDecision,
    required bool redDecision,
    String? shadowFailure,
  }) {
    _seen++;
    if (_pairs.length < maxPairs) {
      _pairs.add(
        ShadowPair(
          index: _seen,
          working: working,
          shadow: shadow,
          whiteDecision: whiteDecision,
          redDecision: redDecision,
          shadowFailure: shadowFailure,
        ),
      );
      return;
    }
    _overflow++;
    if (!_flushed) {
      _flushed = true;
      onReport?.call(report());
    }
  }

  /// Сбрасывает накопленное — при новом прогоне калибровки.
  void reset() {
    _pairs.clear();
    _seen = 0;
    _failures = 0;
    _overflow = 0;
    _flushed = false;
    extractor.resetMotion();
  }

  void dispose() => extractor.dispose();

  /// Рабочие признаки этого же кадра. При открытом `workingExtractor` считать
  /// их заново честнее, чем брать из входа: вход отдаёт признаки, посчитанные
  /// ДО решения, а мы хотим стоять рядом и не путать источники.
  LampFrame _recompute(ShadowInput input) {
    final FeatureExtractor? extractor = workingExtractor;
    if (extractor == null) {
      return input.frame;
    }
    return extractor.extract(input.raw, input.roi, input.mapping);
  }

  /// Таблица «рабочий способ | OpenCV» по всем накопленным кадрам и сводка
  /// расхождений. Только числа, никаких выводов о порогах.
  String report() {
    if (_pairs.isEmpty) {
      return 'теневой измеритель: кадров не увидел';
    }
    final StringBuffer b = StringBuffer();
    b.writeln(
      'OPENCV · сравнение способов на ${_pairs.length} кадрах '
      '(увидено $_seen, не влезло $_overflow, сбоев тени $_failures)',
    );
    b.writeln(
      _row(<String>[
        'кадр',
        'зона',
        'раб сред',
        'ocv сред',
        'раб σ',
        'ocv σ',
        'раб p90',
        'ocv p90',
        'раб кл%',
        'ocv кл%',
        'раб б%',
        'ocv б%',
        'раб к%',
        'ocv к%',
      ]),
    );
    for (final ShadowPair pair in _pairs) {
      _region(b, pair.index, 'бел', pair.working.white, pair.shadow?.whiteCore);
      _region(b, pair.index, 'бел окр', pair.working.whiteRing, pair.shadow?.whiteRing);
      _region(b, pair.index, 'крас', pair.working.red, pair.shadow?.redCore);
      _region(b, pair.index, 'крас окр', pair.working.redRing, pair.shadow?.redRing);
    }
    b.writeln('сводка расхождений (|рабочий − OpenCV|):');
    for (final String line in _summary()) {
      b.writeln('  $line');
    }
    b.writeln(
      'центр − кольцо, среднее по прогону (рабочий | OpenCV): '
      'белая ${_avg((ShadowPair p) => _workingCenterMinusRing(p.working, true))} '
      '| ${_avg((ShadowPair p) => p.shadow?.whiteCenterMinusRing)} · '
      'красная ${_avg((ShadowPair p) => _workingCenterMinusRing(p.working, false))} '
      '| ${_avg((ShadowPair p) => p.shadow?.redCenterMinusRing)}',
    );
    b.writeln(
      'яркость всего поля: рабочий ${_avg((ShadowPair p) => p.working.white.meanY)} '
      '(колпак белой) | OpenCV ${_avg((ShadowPair p) => p.shadow?.frame.meanY)} '
      '(весь кадр) · движение ${_avg((ShadowPair p) => p.shadow?.motionMean)}',
    );
    for (final ShadowPair pair in _pairs) {
      final String? f = pair.shadowFailure;
      if (f != null) {
        b.writeln('сбой кадра ${pair.index}: $f');
      }
    }
    for (final ShadowPair pair in _pairs) {
      for (final String note in pair.shadow?.notes ?? const <String>[]) {
        b.writeln('кадр ${pair.index}: $note');
      }
    }
    return b.toString();
  }

  /// Одна строка таблицы: слева числа рабочего способа, справа OpenCV.
  ///
  /// Прочерк означает «у способа этой зоны просто нет» (ореол после вычитания
  /// сжат в полоску), а не «измерено ноль» — вторая случайность в сравнении
  /// была бы лишней.
  void _region(
    StringBuffer b,
    int index,
    String name,
    FrameFeatures? work,
    OpenCvFeatureMeasure? shadow,
  ) {
    final OpenCvFeatureMeasure s = shadow ?? OpenCvFeatureMeasure.empty;
    String w(String Function(FrameFeatures f) pick) =>
        work == null ? '—' : pick(work);
    String o(String Function(OpenCvFeatureMeasure f) pick) =>
        shadow == null ? '—' : pick(s);
    b.writeln(
      _row(<String>[
        '$index',
        name,
        w((FrameFeatures f) => f.meanY.toStringAsFixed(1)),
        o((OpenCvFeatureMeasure f) => f.meanY.toStringAsFixed(1)),
        w((FrameFeatures f) => f.lumaStdDev.toStringAsFixed(1)),
        o((OpenCvFeatureMeasure f) => f.lumaStdDev.toStringAsFixed(1)),
        w((FrameFeatures f) => f.p90Luma.toStringAsFixed(0)),
        o((OpenCvFeatureMeasure f) => f.p90Luma.toStringAsFixed(0)),
        w((FrameFeatures f) => (f.clippedRatio * 100).toStringAsFixed(1)),
        o((OpenCvFeatureMeasure f) => (f.clippedRatio * 100).toStringAsFixed(1)),
        w((FrameFeatures f) => (f.whiteFrac * 100).toStringAsFixed(1)),
        shadow == null || s.whiteFrac == null
            ? '—'
            : (s.whiteFrac! * 100).toStringAsFixed(1),
        w((FrameFeatures f) => (f.redFrac * 100).toStringAsFixed(1)),
        shadow == null || s.redFrac == null
            ? '—'
            : (s.redFrac! * 100).toStringAsFixed(1),
      ]),
    );
  }

  /// По каждой паре чисел — средняя и максимальная разница. Это и есть ответ
  /// на вопрос «меряют ли оба способа одно и то же»: если максимум мал,
  /// различается только реализация, если велик — различается сам способ, и
  /// решать по нему нельзя.
  List<String> _summary() {
    final List<String> lines = <String>[];
    void diff(
      String title,
      double Function(ShadowPair) work,
      double? Function(ShadowPair) shadow,
    ) {
      double sum = 0;
      double max = 0;
      int n = 0;
      for (final ShadowPair pair in _pairs) {
        final double? s = shadow(pair);
        final double w = work(pair);
        // NaN здесь означает «одной из сторон мерить нечего» (ореол сжат до
        // полоски), а не «измерение нулевое». Такой кадр из сравнения выпадает.
        if (s == null || w.isNaN) {
          continue;
        }
        final double d = (w - s).abs();
        sum += d;
        n++;
        if (d > max) {
          max = d;
        }
      }
      if (n == 0) {
        lines.add('$title: сравнивать нечем');
        return;
      }
      lines.add(
        '$title: средняя ${(sum / n).toStringAsFixed(2)}, '
        'макс ${max.toStringAsFixed(2)} по $n кадрам',
      );
    }

    diff(
      'средняя яркость белого колпака',
      (ShadowPair p) => p.working.white.meanY,
      (ShadowPair p) => p.shadow?.whiteCore.meanY,
    );
    diff(
      'p90 белого колпака',
      (ShadowPair p) => p.working.white.p90Luma,
      (ShadowPair p) => p.shadow?.whiteCore.p90Luma,
    );
    diff(
      'средняя яркость красного колпака',
      (ShadowPair p) => p.working.red.meanY,
      (ShadowPair p) => p.shadow?.redCore.meanY,
    );
    diff(
      'p90 красного колпака',
      (ShadowPair p) => p.working.red.p90Luma,
      (ShadowPair p) => p.shadow?.redCore.p90Luma,
    );
    diff(
      'доля белого в белом колпаке',
      (ShadowPair p) => p.working.white.whiteFrac * 100,
      (ShadowPair p) => p.shadow?.whiteCore.whiteFrac == null
          ? null
          : p.shadow!.whiteCore.whiteFrac! * 100,
    );
    diff(
      'доля красного в красном колпаке',
      (ShadowPair p) => p.working.red.redFrac * 100,
      (ShadowPair p) => p.shadow?.redCore.redFrac == null
          ? null
          : p.shadow!.redCore.redFrac! * 100,
    );
    diff(
      'ореол белой: средняя яркость',
      (ShadowPair p) => p.working.whiteRing?.meanY ?? double.nan,
      (ShadowPair p) => p.shadow?.whiteRing?.meanY,
    );
    return lines;
  }

  /// Рабочий «центр минус кольцо»: у рабочего экстрактора этой величины нет,
  /// она собирается из его же двух измерений, чтобы сравнивать одинаковые
  /// понятия, а не разные слова.
  double? _workingCenterMinusRing(LampFrame frame, bool white) {
    final FrameFeatures core = white ? frame.white : frame.red;
    final FrameFeatures? ring = white ? frame.whiteRing : frame.redRing;
    if (ring == null) {
      return null;
    }
    return core.meanY - ring.meanY;
  }

  String _avg(double? Function(ShadowPair) pick) {
    double sum = 0;
    int n = 0;
    for (final ShadowPair pair in _pairs) {
      final double? v = pick(pair);
      if (v == null || v.isNaN) {
        continue;
      }
      sum += v;
      n++;
    }
    return n == 0 ? '—' : (sum / n).toStringAsFixed(1);
  }

  static String _row(List<String> cells) => cells.join(' │ ');
}
