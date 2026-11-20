/// Световые условия, при которых набраны измерения.
///
/// Экспозиция и чувствительность сенсора — это то ОТНОСИТЕЛЬНО чего сняты все
/// признаки кадра. Эталон, набранный на одной выдержке, бесполезен на другой:
/// то же количество света даёт другие доли пикселей и другую яркость, поэтому
/// скачок экспозиции неотличим от вспышки лампы. Отсюда два требования:
/// «согласованная экспозиция для всех трёх состояний калибровки» и «при
/// изменении экспозиции сбрасывать калибровку».
///
/// Порог здесь ровно один, и он не про свет: платформы отдают метрики сенсора
/// с дрожанием в единицы процентов, и дрожание сменой условий быть не должно.
/// Автоэкспозиция переставляет выдержку шагами, заметно крупнее этого допуска,
/// так что проверка не спорит с камерой из-за округления.
class ExposureGuard {
  ExposureGuard({this.tolerance = jitterTolerance});

  /// Допусс дрожания метрик сенсора, безразмерный.
  final double tolerance;

  static const double jitterTolerance = 0.02;

  int? _ns;
  double? _gain;

  /// Есть ли база сравнения. Без неё решение не принимается: сравнивать не с
  /// чем, а заводить её по первому попавшемуся кадру значило бы сбрасывать
  /// калибровку на пустом месте.
  bool get hasBasis => _ns != null || _gain != null;

  /// Текущая база: выдержка (нс) и чувствительность.
  ({int? ns, double? gain}) get basis => (ns: _ns, gain: _gain);

  /// Запоминает условия как базу измерений. Источник, который метаданные не
  /// отдаёт (файл, симулятор, старая платформа), базы не получает и поэтому
  /// никогда не сбрасывает.
  void remember({int? ns, double? gain}) {
    _ns = ns;
    _gain = gain;
  }

  /// Забыть базу целиком — после сброса калибровки, пока новый набор не начался.
  void clear() {
    _ns = null;
    _gain = null;
  }

  /// Совпадает ли свет с базой. Кадр без меток совпадает: отсутствие данных —
  /// не доказательство смены условий.
  bool matches({int? ns, double? gain}) =>
      !hasBasis || same(_ns, ns, _gain, gain, tolerance: tolerance);

  /// Проверка на каждом кадре: вернула `null` — свет тот же, либо базы не было
  /// и кадр только что её задал. Вернула прежние условия — свет сменился, и
  /// измерения, набранные при нём, недействительны.
  ///
  /// Сменившиеся условия сразу становятся новой базой: иначе каждый следующий
  /// кадр докладывал бы об одном и том же скачке.
  ({int? ns, double? gain})? checkAndAdopt({int? ns, double? gain}) {
    if (!hasBasis) {
      remember(ns: ns, gain: gain);
      return null;
    }
    if (same(_ns, ns, _gain, gain, tolerance: tolerance)) {
      return null;
    }
    final ({int? ns, double? gain}) previous = basis;
    remember(ns: ns, gain: gain);
    return previous;
  }

  /// Одна ли это освещённость. Пара `null` с какой-либо стороны сравниваться
  /// не может и считается одинаковой — проверять нечего.
  static bool same(
    int? aNs,
    int? bNs,
    double? aGain,
    double? bGain, {
    double tolerance = jitterTolerance,
  }) {
    if (aNs != null && bNs != null && !_sameNumber(aNs, bNs, tolerance)) {
      return false;
    }
    if (aGain != null && bGain != null && !_sameNumber(aGain, bGain, tolerance)) {
      return false;
    }
    return true;
  }

  static bool _sameNumber(num a, num b, double tolerance) =>
      (a - b).abs() <= tolerance * a.abs();

  /// Человекочитаемое описание смены условий: по нему в ошибке сессии видно,
  /// что именно сбросило калибровку.
  static String describe({int? aNs, double? aGain, int? bNs, double? bGain}) =>
      'выдержка ${aNs ?? '?'} → ${bNs ?? '?'} нс, '
      'чувствительность ${aGain?.toStringAsFixed(0) ?? '?'} → '
      '${bGain?.toStringAsFixed(0) ?? '?'}';
}
