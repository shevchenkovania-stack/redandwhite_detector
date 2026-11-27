import 'dart:math' as math;
import 'dart:typed_data';

import '../models/feature_profile.dart';
import '../models/frame_features.dart';
import '../models/lamp_config.dart';

/// Семь профилей спецификации v6 §8 плюс опциональный BOTH_ON (§7, шаг 4).
///
/// Собран из состояний калибровки, ничего нового не измеряет: четыре профиля
/// своей лампы и два — того, как ЧУЖОЕ включение выглядит в этой рамке
/// (spill). Именно пара «ON против spill» и есть ответ на §5: кадр обязан быть
/// похож на включение СВОЕЙ лампы, а не просто отличаться от темноты.
final class LampProfiles {
  const LampProfiles({
    required this.whiteOff,
    required this.redOff,
    required this.whiteOn,
    required this.redOn,
    required this.redRoiWhiteSpill,
    required this.whiteRoiRedSpill,
    this.bothOnWhite,
    this.bothOnRed,
  });

  /// Профилей нет вообще — калибровка снята сборкой, которая их не писала.
  static const LampProfiles none = LampProfiles(
    whiteOff: FeatureProfile.empty,
    redOff: FeatureProfile.empty,
    whiteOn: FeatureProfile.empty,
    redOn: FeatureProfile.empty,
    redRoiWhiteSpill: FeatureProfile.empty,
    whiteRoiRedSpill: FeatureProfile.empty,
  );

  /// WHITE_OFF_PROFILE: белая рамка при выключенных лампах.
  final FeatureProfile whiteOff;

  /// RED_OFF_PROFILE: красная рамка при выключенных лампах.
  final FeatureProfile redOff;

  /// WHITE_ON_PROFILE: белая рамка, когда держали белую.
  final FeatureProfile whiteOn;

  /// RED_ON_PROFILE: красная рамка, когда держали красную.
  final FeatureProfile redOn;

  /// RED_ROI_WHITE_SPILL: красная рамка в кадре, где горела белая.
  final FeatureProfile redRoiWhiteSpill;

  /// WHITE_ROI_RED_SPILL: белая рамка в кадре, где горела красная.
  final FeatureProfile whiteRoiRedSpill;

  /// Шаг 4, опциональный: обе лампы горят. Null — шаг не снимался, и это
  /// законно (v6 §7: «Do not require this step if simultaneous activation is
  /// impossible»), поэтому отсутствие профиля не отказ, а просто отсутствие.
  ///
  /// В само решение они пока не входят: `ProfileDecider.verdict` сравнивает
  /// OFF, ON и spill, а spill снят шагами 2 и 3 (чужая рамка того же кадра).
  /// Здесь эти два профиля — записанный ответ на вопрос «измерена ли двойная
  /// засветка» (журнал §52).
  final FeatureProfile? bothOnWhite;
  final FeatureProfile? bothOnRed;

  /// Решение по профилям возможно, только когда есть чем сравнивать: OFF и ON
  /// СВОЕЙ лампы и spill чужого включения в той же рамке. Без любого из четырёх
  /// чисел остаётся прежнее правило перевеса, и это должно быть видно в отчёте,
  /// а не молча подменено нулём.
  bool get canDecide =>
      !whiteOff.isEmpty &&
      !whiteOn.isEmpty &&
      !redOff.isEmpty &&
      !redOn.isEmpty &&
      !redRoiWhiteSpill.isEmpty &&
      !whiteRoiRedSpill.isEmpty;

  /// Профили из собранной калибровки.
  factory LampProfiles.from(LampBaseline baseline) => LampProfiles(
    whiteOff: baseline.background.whiteProfile,
    redOff: baseline.background.redProfile,
    whiteOn: baseline.whiteOn.whiteProfile,
    redOn: baseline.redOn.redProfile,
    // Рядом с эталоном горящей лампы в том же состоянии лежит профиль ЧУЖОЙ
    // зоны того же кадра — это и есть измеренное влияние, его и требовалось
    // начать читать (v6 §7, шаги 2 и 3).
    redRoiWhiteSpill: baseline.whiteOn.redProfile,
    whiteRoiRedSpill: baseline.redOn.whiteProfile,
    bothOnWhite: baseline.bothOn?.whiteProfile,
    bothOnRed: baseline.bothOn?.redProfile,
  );

  /// Сколько кадров стоит за каждым из шести обязательных профилей — строка
  /// в отчёт калибровки: «профили набраны по 30 кадров» или «по 0», и по ней
  /// видно, чем решение реально доказано.
  String describe() =>
      'бел=${whiteOff.frameCount}/${whiteOn.frameCount}, '
      'кр=${redOff.frameCount}/${redOn.frameCount}, '
      'spill=${redRoiWhiteSpill.frameCount}/${whiteRoiRedSpill.frameCount}'
      '${bothOnWhite == null ? '' : ', both=${bothOnWhite!.frameCount}'}';
}

/// Вердикт профиля по одной лампе: насколько кадр похож на её включение и
/// насколько он похож на отражение соседней лампы (v6 §5, §9.7).
final class ProfileVerdict {
  const ProfileVerdict({
    required this.confidence,
    required this.suspicion,
    required this.distanceOff,
    required this.distanceOn,
    required this.distanceSpill,
    this.available = true,
  });

  /// Вердикта нет: профилей не хватает, и решать по ним нечем. Нули здесь —
  /// честное «не измерено», а не «похоже на выключенную лампу»: вызывающий код
  /// обязан проверить [available], прежде чем смотреть на числа.
  static const ProfileVerdict unavailable = ProfileVerdict(
    confidence: 0,
    suspicion: 0,
    distanceOff: 0,
    distanceOn: 0,
    distanceSpill: 0,
    available: false,
  );

  /// Уверенность 0..1: 0 — кадр ровно как выключенная лампа, 1 — как её
  /// откалиброванное включение и ничто чужое.
  final double confidence;

  /// Подозрение 0..1, что подъём — свет соседней лампы. Ниже 0.5 — кадр
  /// ближе к ON, чем к spill.
  final double suspicion;

  /// Три расстояния, из которых всё посчитано: по ним в диагностике видно
  /// ПРИЧИНУ решения, а не только решение (v6 §13).
  final double distanceOff;
  final double distanceOn;
  final double distanceSpill;

  /// True, если числа посчитаны по профилям, а не оставлены потому, что
  /// сравнивать было не с чем.
  final bool available;

  @override
  String toString() =>
      'conf=${(confidence * 100).toStringAsFixed(0)}% '
      'susp=${(suspicion * 100).toStringAsFixed(0)}% '
      'off=${distanceOff.toStringAsFixed(2)} '
      'on=${distanceOn.toStringAsFixed(2)} '
      'spill=${distanceSpill.toStringAsFixed(2)}';
}

/// Оценка кадра по профилям калибровки — §5 и §9 спецификации v6.
///
/// Смысл один: кадр обязан быть похож на ХАРАКТЕРНЫЙ рисунок включения своей
/// лампы, а не просто отличаться от темноты. Поэтому сравниваются три числа, и
/// каждое — в единицах собственного разброса того же признака:
///
/// * `distanceOff` — чем дальше от выключенного состояния (отклик есть);
/// * `distanceOn` — чем ближе к включению, снятому на калибровке;
/// * `distanceSpill` — чем ближе к тому, как эту рамку залила СОСЕДНЯЯ лампа.
///
/// Третье число и есть защита от отражения: если кадр одинаково далёк от
/// темноты и одинаково близок к ON и к spill, доказать, какой лампой он залит,
/// нельзя, и v6 §5 требует в этом случае НЕ подтверждать соседнюю лампу.
final class ProfileDecider {
  ProfileDecider(this.config);

  LampConfig config;

  /// Вердикт по одной лампе. [x] — вектор признаков её же ROI.
  ProfileVerdict verdict({
    required Float64List x,
    required FeatureProfile off,
    required FeatureProfile on,
    required FeatureProfile spill,
  }) {
    if (off.isEmpty || on.isEmpty || spill.isEmpty) {
      return ProfileVerdict.unavailable;
    }
    final double minSigma = config.v6MinSigma;
    final List<V6Feature> features = config.v6CoreFeatures;
    final double dOff = _finite(
      off.distanceOf(x, minSigma: minSigma, features: features),
    );
    final double dOn = _finite(
      on.distanceOf(x, minSigma: minSigma, features: features),
    );
    final double dSpill = _finite(
      spill.distanceOf(x, minSigma: minSigma, features: features),
    );

    // Насколько кадр «как включение», а не «как темнота»: симметричная мера в
    // долях расстояния между двумя эталонами. 0.5 — ровно посередине, то есть
    // доказать ничего нельзя.
    final double evidence =
        (dOff - dOn) / math.max(dOff + dOn, config.v6DScale);
    final double own = (0.5 + 0.5 * evidence).clamp(0.0, 1.0);

    // Насколько ближе spill, чем ON. Знак тот же: положителен — кадр похож на
    // чужое включение в этой рамке сильнее, чем на своё.
    final double spillEdge =
        (dOn - dSpill) / math.max(dOn + dSpill, config.v6DScale);
    final double suspicion = (0.5 + 0.5 * spillEdge).clamp(0.0, 1.0);

    // Отражение снимает уверенность, но не до нуля: спецификация требует не
    // подтверждать лампу, а число должно оставаться сравниваемым между двумя
    // лампами. [LampConfig.v6ReflectionWeight] — во сколько раз подозрение,
    // полное на 1.0, гасит уверенность.
    final double damp =
        1 - config.v6ReflectionWeight * math.max(0.0, suspicion - 0.5) * 2;
    final double confidence = (own * damp.clamp(0.0, 1.0)).clamp(0.0, 1.0);

    return ProfileVerdict(
      confidence: confidence,
      suspicion: suspicion,
      distanceOff: dOff,
      distanceOn: dOn,
      distanceSpill: dSpill,
    );
  }

  /// Профиль, которого нет, отдаёт `infinity`; наружу такое число ходить не
  /// должно — оно отравляет и деление, и лог.
  static double _finite(double v) => v.isFinite ? v : 1e9;
}
