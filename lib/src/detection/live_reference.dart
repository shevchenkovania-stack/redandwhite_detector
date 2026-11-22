import 'dart:math' as math;

import '../models/frame_features.dart';
import '../models/lamp_config.dart';
import 'lamp_calibration.dart';

/// Скользящий «пол» одного признака: процентиль последних кадров.
///
/// Процентиль, а не среднее: вспышка внутри окна сдвигает среднее ровно на
/// столько, чтобы вычесть саму себя, а процентиль от неё не двигается. Окно
/// набирается за ~2 секунды, поэтому смена освещения сцены сама становится
/// новым «полом», без всякой калибровки.
class RollingFloor {
  RollingFloor({required int window, required this.percentile})
    : window = window < 2 ? 2 : window,
      _scratch = List<double>.filled(window < 2 ? 2 : window, 0);

  final int window;

  /// Какой процентиль считать «полом» (0.2 = 20-й).
  final double percentile;

  final List<double> _values = <double>[];
  final List<double> _observed = <double>[];
  final List<double> _scratch;

  int get count => _values.length;

  /// Сколько реальных значений нужно до первого решения.
  int get needed => (window * 0.5).ceil();
  int get missing => count < needed ? needed - count : 0;
  bool get ready => missing == 0;

  void add(double value) {
    _values.add(value);
    if (_values.length > window) {
      _values.removeAt(0);
    }
  }

  void reset() {
    _values.clear();
    _observed.clear();
  }

  /// До [window] последних ярких значений зоны — те кадры, что НЕ вошли в
  /// «пол» (отвергнуты как вспышка или как пересвет). Только по ним меряется размах
  /// канала: значения, принятые в «пол», — это фон, и считать размах по ним
  /// означало бы принять собственное гуляние фона за амплитуду лампы.
  void observeBright(double value) {
    _observed.add(value);
    if (_observed.length > window) {
      _observed.removeAt(0);
    }
  }

  /// Наибольшее из сохранённых ЯРКИХ значений. Null — ярких отклонений не было:
  /// лампа свою амплитуду ещё не показала, и размах неизвестен.
  double? get peak {
    if (_observed.isEmpty) {
      return null;
    }
    double result = _observed.first;
    for (final double value in _observed) {
      if (value > result) {
        result = value;
      }
    }
    return result;
  }

  /// Нижняя граница по набранным значениям. Пустое окно — не ноль, а неизвестность.
  double? get floor {
    final int n = _values.length;
    if (n == 0) {
      return null;
    }
    for (int i = 0; i < n; i++) {
      _scratch[i] = _values[i];
    }
    // Хвост заполняем заведомо большим числом: признаки — доли 0..1, поэтому
    // после сортировки значимые значения остаются в начале.
    for (int i = n; i < window; i++) {
      _scratch[i] = 2.0;
    }
    _scratch.sort();
    final int index = (percentile.clamp(0.0, 1.0) * (n - 1)).round();
    return _scratch[index];
  }

  /// Шум признака внутри окна (выборочное σ).
  double get sigma {
    final int n = _values.length;
    if (n < 2) {
      return 0;
    }
    double sum = 0;
    for (int i = 0; i < n; i++) {
      sum += _values[i];
    }
    final double mean = sum / n;
    double squares = 0;
    for (int i = 0; i < n; i++) {
      final double d = _values[i] - mean;
      squares += d * d;
    }
    return math.sqrt(squares / (n - 1));
  }

  /// Подъём считается только по достаточному окну; иначе решения ещё нет.
  double? rise(double value) {
    final double? reference = floor;
    if (!ready || reference == null) {
      return null;
    }
    return (value - reference).clamp(0.0, 1.0);
  }
}

/// Решение по одному кадру в режиме живого отсчёта.
class LiveReading {
  const LiveReading({
    required this.whiteRise,
    required this.redRise,
    required this.whiteLevel,
    required this.redLevel,
    required this.whiteAboveOn,
    required this.redAboveOn,
    required this.whiteBelowOff,
    required this.redBelowOff,
    required this.warm,
    required this.whiteValid,
    required this.redValid,
    this.whiteNet = 0,
    this.redNet = 0,
  });

  static const LiveReading warmup = LiveReading(
    whiteRise: 0,
    redRise: 0,
    whiteLevel: 0,
    redLevel: 0,
    whiteAboveOn: false,
    redAboveOn: false,
    whiteBelowOff: false,
    redBelowOff: false,
    warm: false,
    whiteValid: false,
    redValid: false,
  );

  /// Подъём над «полом» своей доли: максимум по колпаку и ореолу.
  final double whiteRise;
  final double redRise;

  /// Тот же подъём без общего для обеих рамок света — по нему гистерезис решает
  /// о ВЫКЛЮЧЕНИИ. Включение остаётся на подъёме как он есть ([whiteRise]):
  /// снимать с него чужой свет означало бы перестать видеть слабые вспышки.
  final double whiteNet;
  final double redNet;

  /// Порог включения, от которого считался подъём.
  final double whiteLevel;
  final double redLevel;

  final bool whiteAboveOn;
  final bool redAboveOn;
  final bool whiteBelowOff;
  final bool redBelowOff;

  /// Достаточно ли СВОИХ значений в окне, чтобы двигать этот канал. Невалидный
  /// кадр не означает ни ON, ни OFF: гистерезис сохраняет прежнее состояние.
  final bool whiteValid;
  final bool redValid;

  /// Оба канала набрали достаточные окна. По отдельности готовность смотрится
  /// через [whiteValid] и [redValid].
  final bool warm;
}

/// Внутреннее состояние окон живого отсчёта для сохраняемой диагностики.
/// Это измерения, а не очередное решение: по ним видно, что стало с фоном
/// после движения телефона и на каком кадре окно было сброшено.
class LiveReferenceDiagnostics {
  const LiveReferenceDiagnostics({
    required this.whiteCoreSamples,
    required this.whiteRingSamples,
    required this.redCoreSamples,
    required this.redRingSamples,
    required this.whiteCoreFloor,
    required this.whiteRingFloor,
    required this.redCoreFloor,
    required this.redRingFloor,
    required this.whiteCoreSigma,
    required this.whiteRingSigma,
    required this.redCoreSigma,
    required this.redRingSigma,
    required this.warmupLeft,
    required this.commonRun,
    required this.resetSequence,
    required this.resetReason,
  });

  final int whiteCoreSamples;
  final int whiteRingSamples;
  final int redCoreSamples;
  final int redRingSamples;
  final double? whiteCoreFloor;
  final double? whiteRingFloor;
  final double? redCoreFloor;
  final double? redRingFloor;
  final double whiteCoreSigma;
  final double whiteRingSigma;
  final double redCoreSigma;
  final double redRingSigma;
  final int warmupLeft;
  final int commonRun;

  /// Номер растёт только в кадре сброса: причина остаётся, номер показывает,
  /// что это была за точка записи, а не продолжающийся сброс на каждом кадре.
  final int resetSequence;
  final String resetReason;
}

/// Живой отсчёт: «ноль» берётся из последних кадров, а не из калибровки.
///
/// Почему так: калибровка описывает одну сцену. Сменили набор картинок,
/// размер окна или включили свет в зале — записанный «ноль» перестаёт
/// соответствовать кадру, и канал либо прилипает к «горит» (и больше не
/// отпускает), либо проваливается ниже порога. Живой отсчёт снимает это
/// противоречие: вспышка определяется как подъём над недавним уровнем СВОЕЙ
/// рамки, поэтому работает на любой сцене и переживает смену освещения.
///
/// Калибровка при этом не обязательна: она остаётся самопроверкой «рамка
/// видит лампу», а не источником истины.
///
/// Две задачи решаются здесь отдельно и в одном порядке:
///
/// 1. **Изменился ли свет** — подъём над «полом» своей зоны и её ореола
///    ([RollingFloor]). Ему всё равно, какой природы свет.
/// 2. **Какой физический источник его создал** — яркость четырёх измеряемых
///    областей и асимметрия между ними.
///
/// Цвет в решении не участвует вовсе: пересвеченная красная лампа для сенсора
/// белая, но ложится её свет вокруг КРАСНОЙ рамки, и это различимо всегда.
class LiveReference {
  LiveReference(LampConfig config) : _config = config {
    _build();
  }

  LampConfig _config;

  set config(LampConfig value) {
    // Меняются окно или процентиль — меняется сама измеряемая величина, поэтому
    // окно обязано начаться заново: усреднять прежнее и новое вместе — это
    // вывести «пол» по каше из величин разной природы.
    final bool rebuild =
        value.referenceWindowFrames != _config.referenceWindowFrames ||
        value.referencePercentile != _config.referencePercentile;
    _config = value;
    if (rebuild) {
      _resetWindow('config');
    }
  }

  late RollingFloor _whiteCore;
  late RollingFloor _whiteRing;
  late RollingFloor _redCore;
  late RollingFloor _redRing;

  int _frames = 0;

  /// Сколько кадров подряд растут ОБЕ рамки — кандидат на смену сцены.
  int _commonRun = 0;
  LiveReading _last = LiveReading.warmup;
  String _lastResetReason = 'start';
  int _resetSequence = 0;
  bool _hasWhiteRing = false;
  bool _hasRedRing = false;

  LiveReading get last => _last;

  /// Был ли уже хотя бы один кадр: до него порога показывать нечего.
  bool get hasReading => _frames > 0;

  /// Сколько РЕАЛЬНЫХ значений ещё нужно до готовности каналов. Каналу
  /// достаточно ОДНОЙ набранной зоны (колпак или ореол), поэтому из двух зон
  /// берётся меньший остаток, а не больший.
  int get warmupLeft {
    int channelMissing(RollingFloor core, RollingFloor ring, bool hasRing) =>
        hasRing ? math.min(core.missing, ring.missing) : core.missing;
    return math.max(
      channelMissing(_whiteCore, _whiteRing, _hasWhiteRing),
      channelMissing(_redCore, _redRing, _hasRedRing),
    );
  }

  void reset() => _resetWindow('manual');

  void _build() {
    final int window = _config.referenceWindowFrames;
    final double percentile = _config.referencePercentile;
    _whiteCore = RollingFloor(window: window, percentile: percentile);
    _whiteRing = RollingFloor(window: window, percentile: percentile);
    _redCore = RollingFloor(window: window, percentile: percentile);
    _redRing = RollingFloor(window: window, percentile: percentile);
    _hasWhiteRing = false;
    _hasRedRing = false;
  }

  void _resetWindow(String reason) {
    _build();
    _frames = 0;
    _commonRun = 0;
    _last = LiveReading.warmup;
    _lastResetReason = reason;
    _resetSequence++;
  }

  LiveReferenceDiagnostics get diagnostics => LiveReferenceDiagnostics(
    whiteCoreSamples: _whiteCore.count,
    whiteRingSamples: _whiteRing.count,
    redCoreSamples: _redCore.count,
    redRingSamples: _redRing.count,
    whiteCoreFloor: _whiteCore.floor,
    whiteRingFloor: _whiteRing.floor,
    redCoreFloor: _redCore.floor,
    redRingFloor: _redRing.floor,
    whiteCoreSigma: _whiteCore.sigma,
    whiteRingSigma: _whiteRing.sigma,
    redCoreSigma: _redCore.sigma,
    redRingSigma: _redRing.sigma,
    warmupLeft: warmupLeft,
    commonRun: _commonRun,
    resetSequence: _resetSequence,
    resetReason: _lastResetReason,
  );

  /// Состояние окон одной короткой строкой для LAMPDBG.
  String get debugTag {
    String number(double? value) => value?.toStringAsFixed(3) ?? '-';
    String span(RollingFloor ref) {
      final double? floor = ref.floor;
      final double? peak = ref.peak;
      return floor == null || peak == null
          ? '-'
          : (peak - floor).toStringAsFixed(3);
    }

    return 'ref samples W=${_whiteCore.count}/${_whiteRing.count} '
        'R=${_redCore.count}/${_redRing.count} '
        'floor W=${number(_whiteCore.floor)}/${number(_whiteRing.floor)} '
        'R=${number(_redCore.floor)}/${number(_redRing.floor)} '
        'sigma W=${_whiteCore.sigma.toStringAsFixed(3)}/${_whiteRing.sigma.toStringAsFixed(3)} '
        'R=${_redCore.sigma.toStringAsFixed(3)}/${_redRing.sigma.toStringAsFixed(3)} '
        'span W=${span(_whiteCore)}/${span(_whiteRing)} '
        'R=${span(_redCore)}/${span(_redRing)} '
        'reset=$_lastResetReason left=$warmupLeft';
  }

  /// Оценивает кадр, затем добавляет его в окно: «пол» всегда описывает
  /// прошлое, иначе вспышка вычитала бы саму себя.
  ///
  /// Смена сцены (другой набор картинок, включили свет в зале, поправили рамку)
  /// поднимает ОБЕ рамки сразу, а по спецификации стенда обе лампы одновременно
  /// не горят. Такой подъём вспышкой не считается: пока он держится, каналы не
  /// двигаются, затем окно начинается заново и «пол» берётся уже из новой
  /// сцены. Поэтому перекалибровка при смене картинок не нужна.
  LiveReading step(LampFrame frame) {
    // Чем меряется зона: верхний процентиль яркости области, приведённый к
    // 0..1, чтобы порог окна ([_level]: `referenceNoiseSigmas` × σ и
    // `referenceMinRise`) остался в тех же единицах и не потребовал новых чисел.
    // Процентиль, а не среднее: среднее по плохо наведённой рамке размазывает
    // колпак по тёмному фону, а верх распределения показывает, что засвеченная
    // площадь есть.
    final double whiteCore = _lit(frame.white);
    final double redCore = _lit(frame.red);
    final FrameFeatures? whiteRing = frame.whiteRing;
    final FrameFeatures? redRing = frame.redRing;

    // Ореол меряется той же яркостью, что и колпак. Чужой ореол вычитается
    // геометрически — на уровне колец (FeatureExtractor.extractRing), а не
    // цветом: доля «белых» пикселей в кольце белой лампы росла и от засветки
    // красной (у неё R задирается выше 170, и белый признак считает её белой).
    final double whiteRingValue = whiteRing == null ? 0 : _lit(whiteRing);
    final double redRingValue = redRing == null ? 0 : _lit(redRing);
    _hasWhiteRing = whiteRing != null;
    _hasRedRing = redRing != null;

    final double whiteCoreRise = _whiteCore.rise(whiteCore) ?? 0;
    final double redCoreRise = _redCore.rise(redCore) ?? 0;
    final double whiteRingRise = whiteRing == null
        ? 0
        : (_whiteRing.rise(whiteRingValue) ?? 0);
    final double redRingRise = redRing == null
        ? 0
        : (_redRing.rise(redRingValue) ?? 0);

    final double whiteCoreLevel = _level(_whiteCore);
    final double whiteRingLevel = _level(_whiteRing);
    final double redCoreLevel = _level(_redCore);
    final double redRingLevel = _level(_redRing);

    // Готовность своя у каждого канала и у каждой ЗОНЫ: пустое окно соседа не
    // обнуляет уже рабочий отсчёт. Канал жив, если набрана ХОТЯ БЫ ОДНА его
    // зона: на яркой сцене колпак упирается в потолок сенсора и его окно не
    // набирается, а ореол при этом измеряется — связывание зон через «и»
    // замораживало рабочий канал целиком. Порог ограничен referenceMaxLevel и
    // размахом, поэтому автоматический общий сброс по sigma не нужен.
    final bool whiteValid =
        _whiteCore.ready || (whiteRing != null && _whiteRing.ready);
    final bool redValid = _redCore.ready || (redRing != null && _redRing.ready);

    // Ореол вправе решить канал только тогда, когда сдвинулся и СОБСТВЕННЫЙ
    // колпак. Подъёмом: «бледнение» колпака — это падение той же величины, по
    // которой считается вспышка, а падение яркости вспышкой быть не может по
    // определению (в прежнем цветовом режиме могло: выжженное в оранжево-белое
    // ядро теряло «красные» пиксели, и приходилось слушать обе стороны).
    // Без этого правила кольцо белой лампы слушало засветку от красной: на
    // стенде красные вспышки давали aW 0.12–0.17 при wf 0.002 (колпак чёрный)
    // и считались белыми событиями. Кольцо — усилитель своей лампы, а не
    // ловец чужого света.
    final bool whiteRingHeard =
        _whiteCore.ready && whiteCoreRise >= whiteCoreLevel;
    final bool redRingHeard = _redCore.ready && redCoreRise >= redCoreLevel;

    // Колпак ещё не набран — ведущей становится готовая зона ореола. Это не
    // послабление правила «ореол не ловит чужой свет» в обычной работе: оно
    // действует, только пока собственного колпака нет вовсе, иначе канал
    // оставался бы немым ровно на тех вспышках, ради которых окно набирается.
    final bool whiteRingLeads = !_whiteCore.ready && whiteRing != null;
    final bool redRingLeads = !_redCore.ready && redRing != null;

    final double whiteRise = whiteRingLeads
        ? whiteRingRise
        : whiteRingHeard
        ? math.max(whiteCoreRise, whiteRingRise)
        : whiteCoreRise;
    final double redRise = redRingLeads
        ? redRingRise
        : redRingHeard
        ? math.max(redCoreRise, redRingRise)
        : redCoreRise;
    // Порог показываем тот, по которому канал реально сработал бы: зона с
    // большим подъёмом — ведущая.
    final double whiteLevel = whiteRingLeads
        ? whiteRingLevel
        : whiteRingHeard && whiteRingRise > whiteCoreRise
        ? whiteRingLevel
        : whiteCoreLevel;
    final double redLevel = redRingLeads
        ? redRingLevel
        : redRingHeard && redRingRise > redCoreRise
        ? redRingLevel
        : redCoreLevel;

    // Общее для обеих рамок — это НЕ вспышка одной из них, а свет, лёгший на всю
    // сцену: засветка от соседней лампы, автоэкспозиция, движение фона. Снимаем
    // одно и то же число с обеих сторон и оставляем его только для решения о
    // ВЫКЛЮЧЕНИИ. Без этого канала хватало одного чужого света, чтобы навсегда
    // застрять в «горит»: подъём погасшей рамки держится на уровне засветки
    // (замер 20.11.2026: `lit R=true` сотни кадров подряд), гашение не
    // подтверждается, и все последующие события уходят в оставшийся живым канал.
    final double common = math.min(whiteRise, redRise);
    final double whiteNet = whiteRise - common;
    final double redNet = redRise - common;

    final bool warm = whiteValid && redValid;
    final bool whiteUp =
        whiteValid &&
        (whiteRingLeads
            ? whiteRingRise >= whiteRingLevel
            : whiteCoreRise >= whiteCoreLevel ||
                  (whiteRingHeard && whiteRingRise >= whiteRingLevel));
    final bool redUp =
        redValid &&
        (redRingLeads
            ? redRingRise >= redRingLevel
            : redCoreRise >= redCoreLevel ||
                  (redRingHeard && redRingRise >= redRingLevel));

    // Допуск кадра в «пол» вычисляется до любого решения: по нему же зона
    // сообщает свой ЯРКИЙ пик. Яркие кадры наблюдаются на КАЖДОМ шаге, в том
    // числе на нерешённом (смена сцены, обе рамки выросли): это измерение
    // размаха, а не решение о вспышке. Пропускать такие кадры нельзя — именно
    // на них лампа показывает свою амплитуду, и пик устаревает.
    final double clip = _config.clipLuma;
    final bool whiteCoreDark = _darkSample(
      _whiteCore,
      whiteCore,
      frame.white.p90Luma >= clip,
    );
    final bool redCoreDark = _darkSample(
      _redCore,
      redCore,
      frame.red.p90Luma >= clip,
    );
    final bool whiteRingDark =
        whiteRing != null &&
        _darkSample(_whiteRing, whiteRingValue, whiteRing.p90Luma >= clip);
    final bool redRingDark =
        redRing != null &&
        _darkSample(_redRing, redRingValue, redRing.p90Luma >= clip);
    if (!whiteCoreDark) {
      _whiteCore.observeBright(whiteCore);
    }
    if (!redCoreDark) {
      _redCore.observeBright(redCore);
    }
    if (whiteRing != null && !whiteRingDark) {
      _whiteRing.observeBright(whiteRingValue);
    }
    if (redRing != null && !redRingDark) {
      _redRing.observeBright(redRingValue);
    }

    // Вопрос «какая лампа» задаётся РАНЬШЕ вопроса «не смена ли это сцены».
    // Чужая вспышка поднимает нашу рамку засветкой, но свою — заметно сильнее,
    // и этот перевес (`lampGateAsymmetry` из калибровки, те же 1.5, что требует
    // эталонный вектор) решает кадр, даже когда обе рамки ушли за порог.
    // Прежде такой кадр не решался ничем: каналы стояли, а держись он дольше
    // [_commonRunLimit] — окно перестраивалось и проглатывало саму вспышку
    // (замер 20.11.2026: `aW 0.561 / aR 0.553`, обе выше порога — отсюда и
    // «не считает», и «всё в одну корзину»).
    final double gate = LampCalibration.lampGateAsymmetry;
    bool whiteYielded = redRise >= gate * whiteRise;
    bool redYielded = whiteRise >= gate * redRise;

    // Перевеса по яркости нет — уступать некому. Цвет тут ничего не
    // доказывает: разницу `redFrac − whiteFrac` между рамками даёт не только
    // одна лампа, осветившая всю сцену, но и две разные, горящие
    // одновременно, а на пересвеченном колпаке она ещё и меняет знак
    // (проверено тестом: симметричная сцена `белая 0.30 + красная 0.30` по
    // цвету отдавалась красной лампе). Такой кадр решается ниже как смена
    // сцены, а не угадывается в корзину.
    if (whiteUp && redUp && !whiteYielded && !redYielded) {
      _commonRun++;
      if (_commonRun >= _commonRunLimit) {
        // Сцена шагнула целиком — это не лампы. Новый «пол» набирается заново.
        _resetWindow('scene');
        return _last;
      }
      // Пока непонятно, что это, — ни один канал не двигаем и в окно кадр не
      // пишем: иначе скачок сцены сам станет «полом», а это и есть ошибка.
      final LiveReading holding = LiveReading(
        whiteRise: whiteRise,
        redRise: redRise,
        whiteNet: whiteNet,
        redNet: redNet,
        whiteLevel: whiteLevel,
        redLevel: redLevel,
        whiteAboveOn: false,
        redAboveOn: false,
        whiteBelowOff: false,
        redBelowOff: false,
        warm: true,
        whiteValid: whiteValid,
        redValid: redValid,
      );
      _last = holding;
      return holding;
    }
    _commonRun = 0;

    final double off = _config.offRatio;

    final LiveReading reading = LiveReading(
      whiteRise: whiteRise,
      redRise: redRise,
      whiteNet: whiteNet,
      redNet: redNet,
      whiteLevel: whiteLevel,
      redLevel: redLevel,
      whiteAboveOn: whiteUp && !whiteYielded,
      redAboveOn: redUp && !redYielded,
      // Выключение доказывает СВОЙ свет: сколько чужая лампа ни залила эту
      // рамку, погасшая своя возвращается к общему уровню сцены ([whiteNet]).
      // Ведущая зона берётся та, что решила о включении, — заглушённый ореол
      // (своего колпака не видно) в [whiteRise] не входит и потому не вправе
      // удерживать канал в «не погасло».
      whiteBelowOff: whiteValid && whiteNet < whiteLevel * off,
      redBelowOff: redValid && redNet < redLevel * off,
      warm: warm,
      whiteValid: whiteValid,
      redValid: redValid,
    );

    // Кадр, где лампа горит, в окно НЕ попадает: иначе долгое горение поднимет
    // «пол» до собственной яркости, канал отпустит, и следующая такая же
    // вспышка не будет видна. Окно описывает только тёмное состояние.
    //
    // Кадр на потолке сенсора — то же самое запрещённое состояние, но по другой
    // причине: Y = 255 не различает «лампа горит» и «пересвечен фон», доли цвета
    // там тоже сгорают (замер: выжженный колпак wf 1.000 вошёл в окно «пола»).
    // Такие кадры в окно не пишутся ни при каком решении.
    _add(
      whiteCore: whiteCore,
      redCore: redCore,
      whiteRing: whiteRing == null ? null : whiteRingValue,
      redRing: redRing == null ? null : redRingValue,
      whiteCoreDark: whiteCoreDark,
      redCoreDark: redCoreDark,
      whiteRingDark: whiteRingDark,
      redRingDark: redRingDark,
    );
    _last = reading;
    return reading;
  }

  void _add({
    required double whiteCore,
    required double redCore,
    required double? whiteRing,
    required double? redRing,
    required bool whiteCoreDark,
    required bool redCoreDark,
    required bool whiteRingDark,
    required bool redRingDark,
  }) {
    if (whiteCoreDark) {
      _whiteCore.add(whiteCore);
    }
    if (whiteRing != null && whiteRingDark) {
      _whiteRing.add(whiteRing);
    }
    if (redCoreDark) {
      _redCore.add(redCore);
    }
    if (redRing != null && redRingDark) {
      _redRing.add(redRing);
    }
    _frames++;
  }

  /// Тёмный кадр доказывается значением, а не флагом `up`: во время набора окна
  /// этот флаг ещё не существует, но яркая вспышка всё равно не должна стать «полом».
  bool _darkSample(RollingFloor ref, double value, bool clipped) {
    if (clipped) {
      return false;
    }
    final double? floor = ref.floor;
    // Пока окно не набрано, годится любой непересвеченный кадр: иначе на сцене,
    // где рамка почти всё время яркая, новые значения отвергаются как «не
    // тёмные», окно навсегда остаётся полупустым, а канал — замороженным
    // (замер 21.11.2026: redValid = false на протяжении целых вспышек).
    if (!ref.ready || floor == null) {
      return true;
    }
    return value <= floor + _level(ref);
  }

  /// Порог = шум окна × σ-множитель, но не ниже абсолютного минимума и не выше
  /// потолка: на идеально ровной сцене σ = 0, и «6σ» не защищает от пары
  /// пикселей, а на гуляющей камере «6σ» перерастает максимум подъёма и убивает
  /// канал (см. [LampConfig.referenceMaxLevel]).
  ///
  /// Потолок дополнительно ограничен ПОЛОВИНОЙ СОБСТВЕННОГО РАЗМАХА канала
  /// (наибольшее ЯРКОЕ значение за окно минус «пол»), но не ниже
  /// `referenceMinRise`. Ярких отклонений не было — потолок прежний,
  /// `referenceMaxLevel`: иначе собственное гуляние фона (замер в тесте:
  /// фон 0.04↔0.06) выдало бы себя за амплитуду лампы, уронило порог до
  /// минимума, и следующий шаг фона стал бы событием. Абсолютный
  /// потолок 0.15 предполагал, что у вспышки всегда есть запас яркости: на
  /// пересвеченной рамке (замер 21.11.2026: красная рамка 243/255 от чужой
  /// белой лампы, 255 от своей) весь подъём — 0.05, и канал молчал, а у тусклой
  /// лампы тот же порог не достигался никогда. Половина размаха — порог в
  /// единицах самой лампы: яркой и тусклой достаётся одно правило. Нижняя
  /// граница `referenceMinRise` обязательна: на тёмной сцене размах стремится
  /// к нулю, и порог по размаху без неё начинает считать шум (проверено
  /// прогоном записи: без нижней границы — 7 ложных событий в темноте).
  double _level(RollingFloor ref) {
    final double minRise = _config.referenceMinRise;
    double maxLevel = _config.referenceMaxLevel;
    final double? floor = ref.floor;
    final double? peak = ref.peak;
    if (floor != null && peak != null) {
      final double span = peak - floor;
      if (span > 0) {
        final double bySpan = 0.5 * span;
        final double capped = bySpan > minRise ? bySpan : minRise;
        if (capped < maxLevel) {
          maxLevel = capped;
        }
      }
    }
    final double byNoise = _config.referenceNoiseSigmas * ref.sigma;
    final double capped = byNoise > maxLevel ? maxLevel : byNoise;
    return capped > minRise ? capped : minRise;
  }

  /// Яркость области, приведённая к 0..1 — в те же единицы, в каких живут
  /// цветовые доли. Совпадение единиц намеренное: при переключении способа
  /// решения пороги окна (`referenceMinRise`, множитель σ) не требуют ни одного
  /// нового числа, и сравнить два способа можно по одним и тем же подъёмам.
  ///
  /// Берётся верхний процентиль, а не среднее: среднее по рамке, промазавшей
  /// по колпаку, размазывает вспышку по тёмному фону, а p90 показывает, что
  /// засвеченная площадь в области есть.
  static double _lit(FrameFeatures f) => f.p90Luma / 255.0;

  /// Сколько кадров подряд должны расти обе рамки, чтобы это считалось сменой
  /// сцены. То же число, что подтверждение выключения: это ровно тот интервал,
  /// за который канал обязан погаснуть.
  int get _commonRunLimit =>
      _config.offConfirmFrames < 2 ? 2 : _config.offConfirmFrames;
}
