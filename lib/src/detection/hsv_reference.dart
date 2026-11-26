import 'dart:math' as math;

import '../models/frame_features.dart';
import '../models/hit_event.dart';
import '../models/lamp_config.dart';
import 'live_reference.dart';

/// Скользящее окно одной HSV-доли: «пол», шум и размах в единицах доли
/// цветных пикселей.
///
/// От [RollingFloor] отличается тем, что шум меряется устойчиво (MAD, а не
/// обычное σ), а размах — по всему окну, а не по отобранным «ярким» значениям.
/// Причина в самой величине: доля цветных пикселей во время горения лампы
/// равна примерно единице и висит в окне несколько кадров подряд. Обычное σ по
/// такому окну выросло бы до половины амплитуды лампы, и порог «k·σ» начал бы
/// требовать от следующей вспышки вдвое больше, чем та может дать. MAD остаётся
/// шумом тёмной части, даже если половина окна — горящая лампа.
final class _FracWindow {
  _FracWindow({required int window, required this.percentile})
    : window = window < 2 ? 2 : window,
      _values = <double>[],
      _sorted = <double>[];

  final int window;
  final double percentile;
  final List<double> _values;
  final List<double> _sorted;

  /// Минимум реальных значений до первого решения. Столько же, сколько нужно
  /// MAD: по трём значениям «шум» — это вымысел.
  int get needed => math.max(5, (window * 0.5).ceil());
  int get count => _values.length;
  int get missing => count < needed ? needed - count : 0;
  bool get ready => missing == 0;

  void add(double value) {
    _values.add(value);
    if (_values.length > window) {
      _values.removeAt(0);
    }
  }

  void reset() => _values.clear();

  /// Процентиль окна так же, как его считает `numpy.percentile` (линейная
  /// интерполяция между соседними рангами). Окно переписывается на каждый
  /// запрос, поэтому сортировка — не дешевле и не дороже, чем в [RollingFloor].
  double? pct(double fraction) {
    final int n = _values.length;
    if (n == 0) {
      return null;
    }
    _sorted
      ..clear()
      ..addAll(_values)
      ..sort();
    return _quantile(_sorted, fraction);
  }

  /// Квантиль уже отсортированного списка с линейной интерполяцией между
  /// соседними рангами — ровно как `numpy.percentile`. Отдельной функцией,
  /// потому что MAD требует тот же подсчёт по своему списку.
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

  /// «Пол» — нижний процентиль. Вспышка внутри окна двигает его слабо: 20-й
  /// процентиль 20 кадров остаётся тёмным кадром, сколько бы яркости ни
  /// пришло сверху.
  double? get floor => pct(percentile);

  /// Устойчивый шум: 1.4826 × MAD (медиана модулей отклонений). Множитель
  /// приводит MAD к σ гауссова шума, чтобы [LampConfig.referenceNoiseSigmas]
  /// жил в тех же единицах, что и в режиме живого отсчёта.
  double get sigma {
    final int n = _values.length;
    if (n < 3) {
      return 0;
    }
    final double? median = pct(0.5);
    if (median == null) {
      return 0;
    }
    final List<double> deviations = <double>[
      for (final double value in _values) (value - median).abs(),
    ]..sort();
    return 1.4826 * _quantile(deviations, 0.5);
  }

  /// Размах канала: p95 − p05 по окну. Нужен потолком порога — см. [_level].
  double? get span {
    if (_values.length < 5) {
      return null;
    }
    final double? hi = pct(0.95);
    final double? lo = pct(0.05);
    if (hi == null || lo == null) {
      return null;
    }
    return hi - lo;
  }

  /// Подъём значения над «полом». Null, пока окно не набрано.
  double? rise(double value) {
    final double? reference = floor;
    if (!ready || reference == null) {
      return null;
    }
    final double delta = value - reference;
    return delta > 0 ? delta : 0;
  }
}

/// Величина, по которой калибровка называет вспышку: один ряд `(зона, канал)`
/// или разность двух рядов.
///
/// Ряды — четыре HSV-доли одного кадра: `wCool`, `wWarm` в белой рамке и
/// `rCool`, `rWarm` в красной. Разности нужны потому, что на офисном стенде
/// красная лампа пережигает свой оранжевый колпак в белое пятно: её `wCool`
/// растёт сильнее, чем её же `rWarm`, и единственный честный вопрос — не
/// «сколько красного», а «насколько краснее, чем белого» в той же зоне
/// (замер 25.11.2026, `tools/hsv_decide.py sign`, журнал 37).
final class HsvFeature {
  const HsvFeature(this.a, this.b);

  /// Индекс оцениваемого ряда.
  final int a;

  /// Ряд, который вычитается. `-1` — признак равен просто ряду [a].
  final int b;

  static const List<String> rowNames = <String>[
    'wCool',
    'wWarm',
    'rCool',
    'rWarm',
  ];

  /// Все 16 кандидатов: 4 ряда и 12 упорядоченных разностей. Перебираются все,
  /// потому что заранее не знать, какой из них на этом стенде разделит лампы,
  /// — в этом и состоит отказ от догадки.
  static final List<HsvFeature> candidates =
      List<HsvFeature>.unmodifiable(<HsvFeature>[
        for (int i = 0; i < 4; i++) HsvFeature(i, -1),
        for (int i = 0; i < 4; i++)
          for (int j = 0; j < 4; j++)
            if (i != j) HsvFeature(i, j),
      ]);

  double of(List<double> rows) => b < 0 ? rows[a] : rows[a] - rows[b];

  /// σ признака по σ рядов: у ряда своё, у разности — корень из суммы
  /// квадратов. Ряды одной зоны коррелированы, поэтому оценка грубая, то есть
  /// разделение классов она занижает, а не завышает.
  double sigmaOf(List<double> sigmas) => b < 0
      ? sigmas[a]
      : math.sqrt(sigmas[a] * sigmas[a] + sigmas[b] * sigmas[b]);

  String get name => b < 0 ? rowNames[a] : '${rowNames[a]}-${rowNames[b]}';
}

/// Правило именования вспышки, выученное по трём состояниям калибровки: какой
/// признак считать ([feature]) и где проходит граница между лампами
/// ([threshold]).
///
/// Существует потому, что «белый пиксель = белая лампа» оказалось неверным
/// физически (журнал 36), а числовые пороги это не лечат: на одном стенде
/// красная лампа даёт больший подъём обесцвеченных пикселей, чем белая.
final class HsvSignature {
  const HsvSignature({
    required this.feature,
    required this.threshold,
    required this.highIsWhite,
    required this.separation,
    required this.whiteValue,
    required this.redValue,
  });

  final HsvFeature feature;

  /// Значение признака между двумя состояниями. Считается по подъёмам рядов
  /// над их «полом», то есть в тех же единицах, что и на калибровке.
  final double threshold;

  /// True — большое значение признака означает белую лампу.
  final bool highIsWhite;

  /// Разделение классов, |белая − красная| / средний разброс, в σ. Ниже
  /// [LampConfig.hsvSignatureMinSigmas] правило не принимается вовсе.
  final double separation;

  /// Значения признака, измеренные на калибровке (для логов и разбора).
  final double whiteValue;
  final double redValue;

  /// Имя вспышки по подъёмам четырёх рядов.
  HitColor nameOf(List<double> rises) =>
      feature.of(rises) >= threshold == highIsWhite
      ? HitColor.white
      : HitColor.red;

  /// Лучший из 16 кандидатов или null, если ни один признак не отделяет белую
  /// лампу от красной.
  ///
  /// Ноль сигм на ровной сцене — не «шума нет», а «шаг снят слишком коротко»,
  /// поэтому в знаменатель добавлен [noiseFloor] — минимальная доля пикселей
  /// (0.2 % ROI), ниже которой разброс считаться не может.
  static HsvSignature? learn(
    LampBaseline baseline, {
    required double minSeparation,
    double noiseFloor = 0.002,
  }) {
    final HsvSignature? best = probe(baseline, noiseFloor: noiseFloor);
    if (best == null || best.separation < minSeparation) {
      return null;
    }
    return best;
  }

  /// То же лучшее правило, но БЕЗ проверки [learn.minSeparation]. Нужно отчёту
  /// калибровки: оператор обязан увидеть, НА СКОЛЬКО не хватило разделения, а
  /// не слово «не выучилось» — иначе он переснимает шаг, который снять нельзя
  /// (на iphone красная лампа выбита в белый, и никакого порога там не будет).
  static HsvSignature? probe(
    LampBaseline baseline, {
    double noiseFloor = 0.002,
  }) {
    if (!baseline.isCalibrated) {
      return null;
    }
    final List<double> bg = _rowsOf(baseline.background);
    final List<double> white = _subtract(_rowsOf(baseline.whiteOn), bg);
    final List<double> red = _subtract(_rowsOf(baseline.redOn), bg);
    final List<double> whiteSigma = _sigmasOf(baseline.whiteOn);
    final List<double> redSigma = _sigmasOf(baseline.redOn);
    HsvSignature? best;
    for (final HsvFeature f in HsvFeature.candidates) {
      final double w = f.of(white);
      final double r = f.of(red);
      final double spread =
          (f.sigmaOf(whiteSigma) + f.sigmaOf(redSigma)) / 2 + noiseFloor;
      final double separation = (w - r).abs() / spread;
      if (best != null && separation <= best.separation) {
        continue;
      }
      best = HsvSignature(
        feature: f,
        threshold: (w + r) / 2,
        highIsWhite: w > r,
        separation: separation,
        whiteValue: w,
        redValue: r,
      );
    }
    return best;
  }

  static List<double> _rowsOf(CalibrationState s) => <double>[
    s.white.coolFrac,
    s.white.warmFrac,
    s.red.coolFrac,
    s.red.warmFrac,
  ];

  static List<double> _sigmasOf(CalibrationState s) => <double>[
    s.whiteSigma.coolFrac,
    s.whiteSigma.warmFrac,
    s.redSigma.coolFrac,
    s.redSigma.warmFrac,
  ];

  static List<double> _subtract(List<double> a, List<double> b) => <double>[
    for (int i = 0; i < 4; i++) a[i] - b[i],
  ];

  String get describe =>
      '${feature.name}>=${threshold.toStringAsFixed(3)} '
      '${highIsWhite ? "высокий=Б" : "высокий=К"} '
      'sep=${separation.toStringAsFixed(1)}σ '
      'Б=${whiteValue.toStringAsFixed(3)} К=${redValue.toStringAsFixed(3)}';
}

/// HSV-отсчёт: вспышка = подъём ДОЛИ ЦВЕТНЫХ ПИКСЕЛЕЙ своей зоны.
///
/// Третий способ решения, и он нужен потому, что первые два меряют не то.
/// «Стало ли в рамке светлее» (яркость) и «похож ли кадр на откалиброванный
/// эталон» опираются на яркость, а её на стенде ест автоэкспозиция. Замер по 11
/// видео 23.11.2026 (`tools/hsv_stats.py`, 86 включений, найденных самой
/// моделью): подъём `p90` яркости на этих же включениях 0.068…0.753 при пороге
/// живого отсчёта 0.062…0.15, и в 8 случаях из 86 он до порога не дотягивает —
/// это и есть «не всегда считает вспышку». Доля цветных пикселей поднимается на
/// 0.061…1.0, а оттенок от выдержки и автоэкспозиции не зависит вовсе.
///
/// Дальше за единицами решения нет: «белая» — это доля пикселей, яркая и почти
/// без оттенка ([FrameFeatures.coolFrac]), «красная» — доля пикселей с
/// оттенком около нуля ([FrameFeatures.warmFrac]). Отбор пикселя живёт в
/// `FeatureExtractor`, все числа — в [LampConfig].
///
/// Правила, каждое из которых проверено на записи стенда:
///
/// 1. **Отсчёт скользящий.** «Пол» и порог берутся из последних
///    [LampConfig.referenceWindowFrames] кадров того же признака, поэтому
///    смена освещения в зале не требует калибровки.
/// 2. **Вето по чужому каналу.** Вспышка считается только если подъём СВОЕГО
///    цвета перекрывает подъём ЧУЖОГО КАНАЛА (его зоны) как минимум в
///    [LampConfig.hsvGate] раз. Спецификация говорит, что одновременно две лампы
///    не загораются, — значит при двух подъёмах разом прав тот, что больше.
///    На 11 видео это единственное правило, которое реально режет перетекания:
///    без него 64 белых и 46 красных событий, при gate 1.5 — 46 и 40
///    (`tools/hsv_decide.py sweep`). Вариант «сравнивать чужой цвет в СВОЕЙ
///    зоне» перемерен и отброшен: он даёт 61/46, то есть не мешает почти ничему.
///    Само значение 3.0 выбрано уже по человеческой разметке 23.11.2026: по
///    порядку б/к на 10 записях это 17 ошибок вместо 23 при 1.5
///    (`tools/hsv_decide.py cmp`).
/// 3. **Стоп на потолке сенсора.** Зона залита добела, свой признак почти
///    единица и чужой заметен — цвет в этом кадре не доказать, и состояние
///    канала не меняется ([LampConfig.hsvClipValue], [LampConfig.hsvClipOwn],
///    [LampConfig.hsvClipCross]).
///
/// 4. **Имя берётся у калибровки.** Событие ищется по максимуму четырёх
///    рядов, а какую это лампу — решает граница, выученная по трём состояниям
///    ([signature], [LampConfig.hsvSignatureNaming]). Нужно потому, что
///    догадка «у своей лампы поднят свой канал» на офисном стенде перевёрнута,
///    и правило 2 по одному ей не лечится. Без калибровки этот способ не
///    запускается вовсе (журнал 46).
///
/// Орео́лы не нужны: офлайн-модель проверялась одним квадратным окном 49×49
/// вокруг колпака (`half = 24` в `tools/hsv_decide.py`), и второй области с
/// отдельными правилами в этих замерах просто нет — добавлять её означало бы
/// придумывать правило, которого данные не видели.
class HsvReference {
  HsvReference(LampConfig config) : _config = config {
    _build();
  }

  LampConfig _config;

  set config(LampConfig value) {
    // Окно и процентиль меняют саму измеряемую величину — окно обязано
    // начаться заново, иначе «пол» вычисляется по смеси разнородных значений.
    final bool rebuild =
        value.referenceWindowFrames != _config.referenceWindowFrames ||
        value.referencePercentile != _config.referencePercentile;
    _config = value;
    if (rebuild) {
      _resetWindow('config');
    }
  }

  late _FracWindow _whiteCool;
  late _FracWindow _whiteWarm;
  late _FracWindow _redWarm;
  late _FracWindow _redCool;

  /// Окно общего канала: максимум четырёх рядов. Нужен режиму [signature].
  late _FracWindow _all;

  /// Правило именования, выученное калибровкой. Null — работает прежнее
  /// правило «свой канал сильнее чужого» с вето ([LampConfig.hsvGate]).
  HsvSignature? _signature;

  /// Имя текущего события и признак того, что оно уже засчитано трекером.
  HitColor? _name;
  bool _nameFrozen = false;

  /// Настроить именование событий по калибровке.
  ///
  /// Null — калибровки нет или лампы в трёх состояниях неразличимы, и
  /// детектор остаётся на прежнем правиле. Смена правила меняет смысл
  /// порога, поэтому окна начинаются заново.
  set signature(HsvSignature? value) {
    if (identical(value, _signature)) {
      return;
    }
    _signature = value;
    _resetWindow(value == null ? 'sign-off' : 'sign-on');
  }

  HsvSignature? get signature => _signature;

  int _frames = 0;

  /// Сколько кадров подряд канал может держать «пол» замороженным. Горение
  /// дольше — аварийный выход: сцена могла измениться насовсем (включили свет),
  /// и вечно замороженный «пол» держал бы канал в «горит». ~80 с при 15 к/с.
  static const int _maxHoldFrames = 1200;

  /// Канал горит — окно его зоны не пополняется, «пол» стоит там, где был до
  /// вспышки. Иначе при горении дольше ~80% окна 20-й процентиль догоняет
  /// уровень самой лампы, подъём над ним падает в ноль, детектор «гасит» лампу,
  /// которая ещё горит, и любое мерцание считает вторым ударом. Заодно серия
  /// вспышек без пауз перестаёт задирать «пол».
  bool _whiteHold = false;
  bool _redHold = false;
  int _whiteHoldRun = 0;
  int _redHoldRun = 0;

  /// Сообщить, какие каналы сейчас горят (по состоянию автомата ПОСЛЕ кадра).
  /// Вызывается ровно раз за кадр: счётчик считает кадры удержания.
  void hold({required bool white, required bool red}) {
    _whiteHoldRun = white ? _whiteHoldRun + 1 : 0;
    _redHoldRun = red ? _redHoldRun + 1 : 0;
    if (_signature != null) {
      // В режиме именования окна не замораживаются: офлайн-схема
      // (`tools/hsv_decide.py sign`) считалась без заморозки пола, и перенос
      // уже засчитанного события в другую корзину создал бы второй удар
      // вместо одного, поэтому имя закрепляется на слове трекера «горит».
      _nameFrozen = white || red;
      return;
    }
    _whiteHold = white && _whiteHoldRun <= _maxHoldFrames;
    _redHold = red && _redHoldRun <= _maxHoldFrames;
  }

  /// Сколько кадров подряд не различимы по цвету (зона на потолке сенсора).
  int _clipRun = 0;
  LiveReading _last = LiveReading.warmup;
  String _lastResetReason = 'start';
  int _resetSequence = 0;

  LiveReading get last => _last;

  /// Был ли хотя бы один кадр: до него порога показывать нечего.
  bool get hasReading => _frames > 0;

  /// Сколько реальных значений ещё нужно обеим зонам. Ноль — решения идут.
  int get warmupLeft => _signature == null
      ? math.max(_whiteCool.missing, _redWarm.missing)
      : math.max(_all.missing, _whiteCool.missing);

  void reset() => _resetWindow('manual');

  void _build() {
    final int window = _config.referenceWindowFrames;
    final double percentile = _config.referencePercentile;
    _whiteCool = _FracWindow(window: window, percentile: percentile);
    _whiteWarm = _FracWindow(window: window, percentile: percentile);
    _redWarm = _FracWindow(window: window, percentile: percentile);
    _redCool = _FracWindow(window: window, percentile: percentile);
    _all = _FracWindow(window: window, percentile: percentile);
  }

  void _resetWindow(String reason) {
    _build();
    _frames = 0;
    _clipRun = 0;
    _name = null;
    _nameFrozen = false;
    _whiteHold = false;
    _redHold = false;
    _whiteHoldRun = 0;
    _redHoldRun = 0;
    _last = LiveReading.warmup;
    _lastResetReason = reason;
    _resetSequence++;
  }

  /// Диагностика тех же окон в структуре [LiveReferenceDiagnostics], чтобы CSV
  /// и разбор записей не требовали новой схемы. В этом режиме поля читаются
  /// так: `whiteCore` — своя доля белой зоны (cool), `whiteRing` — чужая доля
  /// той же зоны (warm), `redCore` — своя доля красной зоны (warm),
  /// `redRing` — чужая (cool); `commonRun` — подряд кадров на потолке сенсора.
  LiveReferenceDiagnostics get diagnostics => LiveReferenceDiagnostics(
    whiteCoreSamples: _whiteCool.count,
    whiteRingSamples: _whiteWarm.count,
    redCoreSamples: _redWarm.count,
    redRingSamples: _redCool.count,
    whiteCoreFloor: _whiteCool.floor,
    whiteRingFloor: _whiteWarm.floor,
    redCoreFloor: _redWarm.floor,
    redRingFloor: _redCool.floor,
    whiteCoreSigma: _whiteCool.sigma,
    whiteRingSigma: _whiteWarm.sigma,
    redCoreSigma: _redWarm.sigma,
    redRingSigma: _redCool.sigma,
    warmupLeft: warmupLeft,
    commonRun: _clipRun,
    resetSequence: _resetSequence,
    resetReason: _lastResetReason,
  );

  /// Состояние окон одной короткой строкой для LAMPDBG.
  String get debugTag {
    String number(double? value) => value?.toStringAsFixed(3) ?? '-';
    final HsvSignature? sign = _signature;
    final String nameTag = _name == null
        ? '-'
        : (_name == HitColor.white ? 'Б' : 'К');
    final String naming = sign == null
        ? 'sign=нет'
        : 'sign=${sign.describe} имя=$nameTag${_nameFrozen ? "*" : ""}';
    return 'hsv samples W=${_whiteCool.count}/${_whiteWarm.count} '
        'R=${_redWarm.count}/${_redCool.count} '
        'floor W=${number(_whiteCool.floor)}/${number(_whiteWarm.floor)} '
        'R=${number(_redWarm.floor)}/${number(_redCool.floor)} '
        'sigma W=${_whiteCool.sigma.toStringAsFixed(3)}/${_redWarm.sigma.toStringAsFixed(3)} '
        'span W=${number(_whiteCool.span)} R=${number(_redWarm.span)} '
        'clip=$_clipRun reset=$_lastResetReason left=$warmupLeft '
        '$naming aggFloor=${number(_all.floor)} agg=${number(_all.rise(_lastPeak))}';
  }

  /// Максимум четырёх рядов последнего кадра — нужен только для лога.
  double _lastPeak = 0;

  /// Шаг по кадру. Порядок — как в проверенной офлайн-модели
  /// (`tools/hsv_decide.py`): значение сначала попадает в окно, решение
  /// считается по окну вместе с ним. При 20-м перцентиле окна в 20 кадров
  /// вспышка не сдвигает «пол» — держать её за его пределами, как в режиме
  /// яркости, здесь не нужно.
  ///
  /// Если калибровкой задано правило [signature], кадр решает не этот метод,
  /// а [_stepSignature]: там нет ни вето по чужому каналу, ни заморозки пола.
  LiveReading step(LampFrame frame) {
    final HsvSignature? sign = _signature;
    if (sign != null) {
      return _stepSignature(frame, sign);
    }
    final double whiteCool = frame.white.coolFrac;
    final double whiteWarm = frame.white.warmFrac;
    final double redWarm = frame.red.warmFrac;
    final double redCool = frame.red.coolFrac;

    // Горящий канал «пол» не двигает (см. [hold]).
    if (!_whiteHold) {
      _whiteCool.add(whiteCool);
      _whiteWarm.add(whiteWarm);
    }
    if (!_redHold) {
      _redWarm.add(redWarm);
      _redCool.add(redCool);
    }
    _frames++;

    final bool whiteValid = _whiteCool.ready;
    final bool redValid = _redWarm.ready;

    final double? whiteRise = _whiteCool.rise(whiteCool);
    final double? redRise = _redWarm.rise(redWarm);
    // Вето сравнивает подъём СВОЕГО канала с подъёмом ЧУЖОГО КАНАЛА (его зоны),
    // а не с чужим цветом в той же зоне. Это не тонкость формулировки: на 11
    // видео первый вариант даёт 46 белых и 40 красных событий против 64/46 без
    // вето, второй — 61/46, то есть почти ничего не мешает (`hsv_decide.py
    // sweep`). Окна чужих цветов (`_whiteWarm`, `_redCool`) остаются: по ним
    // считается стоп на потолке сенсора и диагностика.
    final double whiteBlock = redRise ?? 0;
    final double redBlock = whiteRise ?? 0;

    final double whiteLevel = _level(_whiteCool);
    final double redLevel = _level(_redWarm);

    // Зона упёрлась в потолок сенсора, свой признак почти единица, а чужой
    // заметен: по такому кадру нельзя доказать, какой лампой он залит, — ни в
    // одну корзину. Кадр не двигает канал (ни ON, ни OFF).
    final bool whiteClip = _clipped(frame.white, whiteCool, whiteWarm);
    final bool redClip = _clipped(frame.red, redWarm, redCool);
    _clipRun = (whiteClip || redClip) ? _clipRun + 1 : 0;

    final bool warm = whiteValid && redValid;
    if (whiteRise == null && redRise == null) {
      _last = LiveReading.warmup;
      return _last;
    }

    final double gate = _config.hsvGate;
    // Пересвет ЛЮБОЙ зоны делает кадр недоказуемым для обоих каналов: ядро
    // пересвеченной красной лампы теряет оттенок (`warm` падает, вето слепнет),
    // а её ореол в белой зоне — яркий и бесцветный, то есть «белый». Раньше
    // стоп действовал только на канал самой залитой зоны, и красная вспышка
    // уходила в белую корзину.
    final bool anyClip = whiteClip || redClip;
    final bool whiteHot =
        whiteValid &&
        !anyClip &&
        whiteRise != null &&
        whiteRise > whiteLevel &&
        whiteRise >= gate * whiteBlock;
    final bool redHot =
        redValid &&
        !anyClip &&
        redRise != null &&
        redRise > redLevel &&
        redRise >= gate * redBlock;

    // Гашение доказывает свой признак: он обязан вернуться к «полу». Порог
    // гистерезиса общий с прочими режимами ([LampConfig.offRatio]).
    final double off = _config.offRatio;
    final double? whiteFloor = _whiteCool.floor;
    final double? redFloor = _redWarm.floor;

    final LiveReading reading = LiveReading(
      whiteRise: whiteRise ?? 0,
      redRise: redRise ?? 0,
      // В этих единицах «net» — тот же подъём своего цвета: чужой свет здесь
      // снимается не вычитанием общего, а вето по чужому подъёму ([gate]).
      whiteNet: whiteRise ?? 0,
      redNet: redRise ?? 0,
      whiteLevel: whiteLevel,
      redLevel: redLevel,
      whiteAboveOn: whiteHot,
      redAboveOn: redHot,
      whiteBelowOff:
          whiteValid &&
          !whiteClip &&
          whiteFloor != null &&
          whiteCool <= whiteFloor + off * whiteLevel,
      redBelowOff:
          redValid &&
          !redClip &&
          redFloor != null &&
          redWarm <= redFloor + off * redLevel,
      warm: warm,
      whiteValid: whiteValid,
      redValid: redValid,
    );
    _last = reading;
    return reading;
  }

  /// Кадр в режиме выученного правила. Отличие от [step] одно, но принципиальное:
  /// вспышку ищет не «свой канал», а общее — максимум четырёх рядов, потому что
  /// на этом стенде ни один ряд не является «своим» (журнал 36). Из-за этого здесь
  /// нет вето по чужому каналу: спор двух подъёмов заменил один признак, и
  /// сравнивать два канала больше нечем. Стоп на потолке сенсора тоже нет: он
  /// снимал решение «какой лампой залит кадр», а имя кадра здесь решает
  /// [signature], а не доказательство от цвета.
  ///
  /// Отступление от офлайн-схемы, которое надо увидеть в логах: офлайн событие
  /// называлось по ПИКУ вспышки, а здесь — по последнему кадру до того, как
  /// трекер его подтвердит (обычно 1…2 кадра от начала).
  LiveReading _stepSignature(LampFrame frame, HsvSignature sign) {
    final List<double> rows = <double>[
      frame.white.coolFrac,
      frame.white.warmFrac,
      frame.red.coolFrac,
      frame.red.warmFrac,
    ];
    final double peak = rows.reduce(math.max);
    _lastPeak = peak;

    // Все четыре ряда двигают свои окна всегда: заморозки пола в этой схеме не
    // было ни одного замера.
    _whiteCool.add(rows[0]);
    _whiteWarm.add(rows[1]);
    _redCool.add(rows[2]);
    _redWarm.add(rows[3]);
    _all.add(peak);
    _frames++;

    final double? rise = _all.rise(peak);
    if (rise == null) {
      _last = LiveReading.warmup;
      return _last;
    }
    final bool ready = _all.ready;
    final double level = _level(_all);
    final double? floor = _all.floor;
    final bool hot = ready && rise > level;
    // Гашение доказывает тот же общий канал: он обязан вернуться к «полу».
    final bool cold =
        ready && floor != null && peak <= floor + _config.offRatio * level;

    // Имя уточняется, пока событие не засчитано; после подтверждения трекером
    // его не переносить (см. [hold]).
    if (hot && !_nameFrozen) {
      _name = sign.nameOf(<double>[
        _whiteCool.rise(rows[0]) ?? 0,
        _whiteWarm.rise(rows[1]) ?? 0,
        _redCool.rise(rows[2]) ?? 0,
        _redWarm.rise(rows[3]) ?? 0,
      ]);
    }
    if (cold) {
      _name = null;
      _nameFrozen = false;
    }

    // Пересвет считается и пишется в лог, но на решение не влияет: в этой схеме
    // кадр остаётся доказуемым, чем бы он ни был залит.
    final bool whiteClip = _clipped(frame.white, rows[0], rows[1]);
    final bool redClip = _clipped(frame.red, rows[3], rows[2]);
    _clipRun = (whiteClip || redClip) ? _clipRun + 1 : 0;

    final LiveReading reading = LiveReading(
      // Оба канала несут один и тот же подъём общего ряда: имя у события одно,
      // и «перевес» одного над другим в этих единицах не существует.
      whiteRise: rise,
      redRise: rise,
      whiteNet: rise,
      redNet: rise,
      whiteLevel: level,
      redLevel: level,
      whiteAboveOn: hot && _name == HitColor.white,
      redAboveOn: hot && _name == HitColor.red,
      whiteBelowOff: cold,
      redBelowOff: cold,
      warm: ready,
      whiteValid: ready,
      redValid: ready,
    );
    _last = reading;
    return reading;
  }

  /// Порог: шум × множитель, но не ниже [LampConfig.hsvMinRise] и не выше
  /// [LampConfig.hsvMaxLevel] и половины собственного размаха.
  ///
  /// Потолок нужен потому, что ушедшая в движение камера раздувает шум окна до
  /// 0.12…0.25, и «6σ» становится 0.755 при худшей измеренной вспышке 0.215
  /// (замер 191508) — канал молчал бы всегда. Половина размаха ограничивает
  /// порог амплитудой самой лампы: яркой и тусклой достаётся одно правило.
  double _level(_FracWindow window) {
    final double minRise = _config.hsvMinRise;
    double maxLevel = _config.hsvMaxLevel;
    final double? span = window.span;
    if (span != null && span > 0) {
      final double bySpan = 0.5 * span;
      final double capped = bySpan > minRise ? bySpan : minRise;
      if (capped < maxLevel) {
        maxLevel = capped;
      }
    }
    final double byNoise = _config.referenceNoiseSigmas * window.sigma;
    final double level = byNoise > maxLevel ? maxLevel : byNoise;
    return level > minRise ? level : minRise;
  }

  /// Кадр на потолке сенсора, в котором цвет не различим. Яркость берётся
  /// p90 зоны в долях — то же число, по которому живой отсчёт меряет свет.
  bool _clipped(FrameFeatures zone, double own, double cross) =>
      zone.p90Luma / 255.0 >= _config.hsvClipValue &&
      own >= _config.hsvClipOwn &&
      cross >= _config.hsvClipCross;
}
