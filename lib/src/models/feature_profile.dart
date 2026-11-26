import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_features.dart';

/// Распределение ОДНОГО признака, снятое по кадрам состояния (v6 §8).
///
/// Здесь median и квартильные границы, а не среднее с σ и не «мин/макс»:
/// спецификация требует хранить распределения и прямо запрещает считать
/// сырой минимум/максимум единственной границей профиля. Причина не вкусовая, а
/// из замеров калибровки: один кадр с прошедшей рукой или мигнувшей лампой
/// уводит min/max и среднее так, что следующий рабочий кадр не похож ни на один
/// эталон, — медиана и квартили от одного такого кадра почти не двигаются.
final class FeatureDistribution {
  const FeatureDistribution({
    required this.median,
    required this.p05,
    required this.p25,
    required this.p75,
    required this.p95,
    required this.count,
  });

  /// Пустое распределение — признак не измерялся (старая калибровка).
  static const FeatureDistribution empty = FeatureDistribution(
    median: 0,
    p05: 0,
    p25: 0,
    p75: 0,
    p95: 0,
    count: 0,
  );

  final double median;
  final double p05;
  final double p25;
  final double p75;
  final double p95;

  /// Сколько кадров стояло за этими числами. 0 — состояние не снято.
  final int count;

  bool get isEmpty => count == 0;

  /// Устойчивый разброс: межквартильный интервал, приведённый к σ гауссова
  /// шума (деление на 1.349). Берётся не MAD, потому что MAD по уже
  /// посчитанным квартилям недоступен, а IQR стоит на тех же двух кадрах
  /// внутри окна в 30 кадров, что и MAD.
  double get iqrSigma => (p75 - p25) / 1.349;

  /// Разброс этого признака в ЕГО СОБСТВЕННЫХ единицах — то, на что делится
  /// отклонение кадра.
  ///
  /// Пол привязан к уровню признака ([minSigma] в долях от median), а не к
  /// одному абсолютному числу, потому что вектор смешан по шкалам: `medianV`
  /// лежит в 0..255, а `coreAreaFrac` — в 0..1, и один глобальный «пол в
  /// 0.01» для яркости означал бы «шума нет вообще».
  ///
  /// Нулевой результат — признак ничему не учит ([notDiscriminating]): ровная
  /// синтетика, где медиана стоит на нуле и квартили не двинулись, не даёт ни
  /// подтверждения, ни опровержения, и врать «бесконечное отклонение» здесь не
  /// чем.
  double sigmaOf(double minSigma) =>
      math.max(iqrSigma, minSigma * median.abs());

  bool get notDiscriminating => median == 0 && iqrSigma == 0;

  /// Профиль по [values]: медиана и процентили тех же значений, что собрала
  /// калибровка. Пустой список — [empty].
  static FeatureDistribution fromValues(List<double> values) {
    if (values.isEmpty) {
      return empty;
    }
    final List<double> sorted = List<double>.of(values)..sort();
    return FeatureDistribution(
      median: _quantile(sorted, 0.5),
      p05: _quantile(sorted, 0.05),
      p25: _quantile(sorted, 0.25),
      p75: _quantile(sorted, 0.75),
      p95: _quantile(sorted, 0.95),
      count: sorted.length,
    );
  }

  /// Квантиль отсортированного списка с линейной интерполяцией между рангами —
  /// та же схема, что в `HsvReference._quantile`, чтобы калибровка и прогон
  /// считали процентиль одинаково.
  static double _quantile(List<double> sorted, double fraction) {
    final int n = sorted.length;
    final double pos = (n - 1) * fraction.clamp(0.0, 1.0);
    final int lo = pos.floor();
    final int hi = pos.ceil();
    if (lo == hi) {
      return sorted[lo];
    }
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  List<Object?> toJson() => <Object?>[
    median,
    p05,
    p25,
    p75,
    p95,
    count,
  ];

  static FeatureDistribution fromJson(Object? raw) {
    if (raw is! List || raw.length < 6) {
      return empty;
    }
    return FeatureDistribution(
      median: (raw[0] as num?)?.toDouble() ?? 0,
      p05: (raw[1] as num?)?.toDouble() ?? 0,
      p25: (raw[2] as num?)?.toDouble() ?? 0,
      p75: (raw[3] as num?)?.toDouble() ?? 0,
      p95: (raw[4] as num?)?.toDouble() ?? 0,
      count: (raw[5] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'med=${median.toStringAsFixed(3)} '
      'iqrσ=${iqrSigma.toStringAsFixed(4)} n=$count';
}

/// Профиль одной области: распределение каждого признака вектора [V6Feature].
///
/// Это и есть то, что спецификация v6 §8 называет WHITE_OFF_PROFILE,
/// RED_ON_PROFILE и spill-профилем: не одно число на признак, а картина, с
/// которой сравнивается кадр.
final class FeatureProfile {
  const FeatureProfile({required this.distributions, required this.frameCount});

  /// Профиль, которого нет: пустой вектор и ноль кадров.
  static const FeatureProfile empty = FeatureProfile(
    distributions: <FeatureDistribution>[],
    frameCount: 0,
  );

  final List<FeatureDistribution> distributions;
  final int frameCount;

  bool get isEmpty => frameCount == 0 || distributions.length != V6Feature.count;

  /// Профиль по кадрам одного состояния.
  static FeatureProfile fromFrames(List<FrameFeatures> frames) {
    if (frames.isEmpty) {
      return empty;
    }
    final int n = V6Feature.count;
    final List<List<double>> columns = <List<double>>[
      for (int i = 0; i < n; i++) <double>[],
    ];
    for (final FrameFeatures f in frames) {
      final Float64List v = f.toVector();
      for (int i = 0; i < n; i++) {
        columns[i].add(v[i]);
      }
    }
    return FeatureProfile(
      distributions: <FeatureDistribution>[
        for (int i = 0; i < n; i++) FeatureDistribution.fromValues(columns[i]),
      ],
      frameCount: frames.length,
    );
  }

  FeatureDistribution operator [](V6Feature f) => distributions[f.index];

  /// Насколько вектор [x] похож на этот профиль: среднее |z| по тем признакам,
  /// которые профиль реально различает. Полный список признаков — у
  /// [distanceOf], здесь просто без выбора признаков.
  double distance(Float64List x, {required double minSigma}) =>
      distanceOf(x, minSigma: minSigma, features: V6Feature.values);

  /// Расстояние по ограниченному числу признаков — тем, что решение считает
  /// существенными ([features]).
  ///
  /// Признак пропускается, если его разброс нулевой: по постоянному числу
  /// нельзя ни подтвердить, ни опровергнуть, и выдуманное «огромное
  /// отклонение» сюда попадать не должно.
  double distanceOf(
    Float64List x, {
    required double minSigma,
    required List<V6Feature> features,
  }) {
    if (isEmpty) {
      return double.infinity;
    }
    double sum = 0;
    int used = 0;
    for (final V6Feature f in features) {
      final FeatureDistribution d = distributions[f.index];
      if (d.isEmpty || d.notDiscriminating) {
        continue;
      }
      final double sigma = d.sigmaOf(minSigma);
      if (sigma <= 0) {
        continue;
      }
      sum += (x[f.index] - d.median).abs() / sigma;
      used++;
    }
    if (used == 0) {
      return double.infinity;
    }
    return sum / used;
  }

  /// Сколько признаков профиль реально измеряет — число, которое отчёт обязан
  /// показать: профиль из четырёх живых признаков и профиль из пятнадцати
  /// назваются одинаковым словом «профиль», хотя доказывают разное.
  int get liveFeatureCount {
    if (isEmpty) {
      return 0;
    }
    int n = 0;
    for (final FeatureDistribution d in distributions) {
      if (!d.isEmpty && !d.notDiscriminating && d.iqrSigma > 0) {
        n++;
      }
    }
    return n;
  }

  List<Object?> toJson() => <Object?>[
    frameCount,
    <Object?>[for (final FeatureDistribution d in distributions) d.toJson()],
  ];

  static FeatureProfile fromJson(Object? raw) {
    if (raw is! List || raw.length < 2 || raw[1] is! List) {
      return empty;
    }
    final List<Object?> list = raw[1] as List<Object?>;
    if (list.length != V6Feature.count) {
      return empty;
    }
    return FeatureProfile(
      distributions: <FeatureDistribution>[
        for (final Object? d in list) FeatureDistribution.fromJson(d),
      ],
      frameCount: (raw[0] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'FeatureProfile(n=$frameCount, live=$liveFeatureCount/'
      '${V6Feature.count})';
}
