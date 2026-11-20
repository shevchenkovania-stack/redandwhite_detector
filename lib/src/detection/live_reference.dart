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
  final List<double> _scratch;

  int get count => _values.length;

  void add(double value) {
    _values.add(value);
    if (_values.length > window) {
      _values.removeAt(0);
    }
  }

  void reset() => _values.clear();

  /// Нижняя граница признака по последним кадрам.
  double get floor {
    final int n = _values.length;
    if (n == 0) {
      return 0;
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

  /// Насколько признак выше «пола».
  double rise(double value) => (value - floor).clamp(0.0, 1.0);

  /// Насколько признак УПАЛ под «пол». Нужно для того же ореола: у настоящей
  /// лампы колпак при включении может побледнеть (замер redFrac 0.727 → 0.630,
  /// ядро выжжено в оранжево-белое), и движение в любую сторону доказывает,
  /// что лампа реагирует.
  double drop(double value) => (floor - value).clamp(0.0, 1.0);
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
    whiteBelowOff: true,
    redBelowOff: true,
    warm: false,
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

  /// Окно ещё не набрано: решения не выдаются, чтобы первый же кадр не стал
  /// «вспышкой» из-за нулевого «пола». Ниже OFF — канал в прогреве считается
  /// погасшим, иначе он мог бы залипнуть в «горит» и молчать весь прогон.
  final bool warm;
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
/// 2. **Какой физический источник его создал** — в цветовом режиме это доля
///    «своих» пикселей, в пространственном ([LampConfig.spatialVectors]) —
///    яркость четырёх измеряемых областей и асимметрия между ними.
///
/// Во втором режиме цвет в решении не участвует вовсе: пересвеченная красная
/// лампа для сенсора белая, но ложится её свет вокруг КРАСНОЙ рамки, и это
/// различимо всегда.
class LiveReference {
  LiveReference(LampConfig config) : _config = config {
    _build();
  }

  LampConfig _config;

  set config(LampConfig value) {
    // Смена способа решения меняет МЕРЯЕМУЮ величину (долю пикселей — на
    // яркость области), поэтому окно обязано начаться заново: усреднять их
    // вместе — это вывести «пол» по каше из величин разной природы.
    final bool rebuild =
        value.referenceWindowFrames != _config.referenceWindowFrames ||
        value.referencePercentile != _config.referencePercentile ||
        value.spatialVectors != _config.spatialVectors;
    _config = value;
    if (rebuild) {
      _build();
      _frames = 0;
      _commonRun = 0;
      _unstableRun = 0;
      _last = LiveReading.warmup;
    }
  }

  late RollingFloor _whiteCore;
  late RollingFloor _whiteRing;
  late RollingFloor _redCore;
  late RollingFloor _redRing;

  int _frames = 0;

  /// Сколько кадров подряд порог упирается в потолок [LampConfig.referenceMaxLevel].
  /// Это не лампы, а камера, гуляющая по сцене: окно с таким шумом не описывает
  /// темноту, и решение по нему выдавать нечем.
  int _unstableRun = 0;

  /// Сколько кадров подряд растут ОБЕ рамки — кандидат на смену сцены.
  int _commonRun = 0;
  LiveReading _last = LiveReading.warmup;

  LiveReading get last => _last;

  /// Был ли уже хотя бы один кадр: до него порога показывать нечего.
  bool get hasReading => _frames > 0;

  /// Сколько кадров ещё нужно, чтобы окно считалось набранным.
  int get warmupLeft {
    final int need = (_config.referenceWindowFrames * 0.5).ceil();
    return need > _frames ? need - _frames : 0;
  }

  void reset() {
    _build();
    _frames = 0;
    _commonRun = 0;
    _unstableRun = 0;
    _last = LiveReading.warmup;
  }

  void _build() {
    final int window = _config.referenceWindowFrames;
    final double percentile = _config.referencePercentile;
    _whiteCore = RollingFloor(window: window, percentile: percentile);
    _whiteRing = RollingFloor(window: window, percentile: percentile);
    _redCore = RollingFloor(window: window, percentile: percentile);
    _redRing = RollingFloor(window: window, percentile: percentile);
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
    final bool spatial = _config.spatialVectors;
    // Чем именно меряется зона. В цветовом режиме это доля «своих» пикселей, в
    // пространственном — верхний процентиль яркости той же области, приведённый
    // к 0..1, чтобы порог окна ([_level]: `referenceNoiseSigmas` × σ и
    // `referenceMinRise`) остался в тех же единицах и не потребовал новых чисел.
    // Процентиль, а не среднее: среднее по плохо наведённой рамке размазывает
    // колпак по тёмному фону, а верх распределения показывает, что засвеченная
    // площадь есть.
    final double whiteCore = spatial ? _lit(frame.white) : frame.white.whiteFrac;
    final double redCore = spatial ? _lit(frame.red) : frame.red.redFrac;
    final FrameFeatures? whiteRing = frame.whiteRing;
    final FrameFeatures? redRing = frame.redRing;

    // Ореол каждой лампы меряется «очищенным» от чужого цвета. Пиксель, который
    // в кольце белой лампы одновременно и «белый», и «красный», — это засветка
    // от КРАСНОЙ лампы, перекормившая сенсор: у неё R задирается выше 170, и
    // белый признак считает её белой. В настоящем белом свете redFrac того же
    // кольца стоит на шуме, поэтому вычитание у белой лампы ничего не отнимает
    // (и симметрично у красной). Без этой очистки красные вспышки на стенде
    // давали aW 0.12–0.17 при wf 0.002 (колпак чёрный) и улетали в «белую».
    // В яркостном режиме вычитать нечего: цвета там нет, а чужой ореол уже
    // вычитается геометрически — на уровне колец (FeatureExtractor.extractRing).
    final double whiteRingValue = whiteRing == null
        ? 0
        : spatial
            ? _lit(whiteRing)
            : (whiteRing.whiteFrac - whiteRing.redFrac).clamp(0.0, 1.0);
    final double redRingValue = redRing == null
        ? 0
        : spatial
            ? _lit(redRing)
            : (redRing.redFrac - redRing.whiteFrac).clamp(0.0, 1.0);

    final double whiteCoreRise = _whiteCore.rise(whiteCore);
    final double redCoreRise = _redCore.rise(redCore);
    final double whiteRingRise = whiteRing == null ? 0 : _whiteRing.rise(whiteRingValue);
    final double redRingRise = redRing == null ? 0 : _redRing.rise(redRingValue);

    final double whiteCoreLevel = _level(_whiteCore);
    final double whiteRingLevel = _level(_whiteRing);
    final double redCoreLevel = _level(_redCore);
    final double redRingLevel = _level(_redRing);

    // Порог, упёршийся в потолок, — это уже не защита от шума, а сломанный
    // отсчёт: подъём ограничен 1.0, а `6σ` не ограничен ничем, так что канал
    // замолкает до перезапуска (замер 20.11.2026: onW 1.256 / onR 1.521 при
    // реальном подъёме 0.561). Такое окно не лечится ничем, кроме набора
    // заново: кадры с ним не оцениваются и в окно не пишутся.
    final double maxLevel = _config.referenceMaxLevel;
    final bool unstable = whiteCoreLevel >= maxLevel ||
        whiteRingLevel >= maxLevel ||
        redCoreLevel >= maxLevel ||
        redRingLevel >= maxLevel;
    _unstableRun = unstable ? _unstableRun + 1 : 0;
    if (_unstableRun >= _commonRunLimit) {
      _build();
      _frames = 0;
      _commonRun = 0;
      _unstableRun = 0;
      _last = LiveReading.warmup;
      return _last;
    }

    // Ореол вправе решить канал только тогда, когда сдвинулся и СОБСТВЕННЫЙ
    // колпак — в любую сторону (у красной лампы он при включении бледнеет).
    // Без этого правила кольцо белой лампы слушало засветку от красной: на
    // стенде красные вспышки давали aW 0.12–0.17 при wf 0.002 (колпак чёрный)
    // и считались белыми событиями. Кольцо — усилитель своей лампы, а не
    // ловец чужого света.
    //
    // В яркостном режиме «бледнение» колпака — это падение той же величины, по
    // которой и считается вспышка, поэтому достаточно подъёма: падение яркости
    // вспышкой быть не может по определению.
    final bool whiteRingHeard = spatial
        ? whiteCoreRise >= whiteCoreLevel
        : whiteCoreRise >= whiteCoreLevel || _whiteCore.drop(whiteCore) >= whiteCoreLevel;
    final bool redRingHeard = spatial
        ? redCoreRise >= redCoreLevel
        : redCoreRise >= redCoreLevel || _redCore.drop(redCore) >= redCoreLevel;

    final double whiteRise =
        whiteRingHeard ? math.max(whiteCoreRise, whiteRingRise) : whiteCoreRise;
    final double redRise =
        redRingHeard ? math.max(redCoreRise, redRingRise) : redCoreRise;
    // Порог показываем тот, по которому канал реально сработал бы: зона с
    // большим подъёмом — ведущая.
    final double whiteLevel =
        whiteRingHeard && whiteRingRise > whiteCoreRise ? whiteRingLevel : whiteCoreLevel;
    final double redLevel =
        redRingHeard && redRingRise > redCoreRise ? redRingLevel : redCoreLevel;

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

    final bool warm = warmupLeft == 0;
    final bool whiteUp = warm &&
        (whiteCoreRise >= whiteCoreLevel ||
            (whiteRingHeard && whiteRingRise >= whiteRingLevel));
    final bool redUp = warm &&
        (redCoreRise >= redCoreLevel || (redRingHeard && redRingRise >= redRingLevel));

    // Вопрос «какая лампа» задаётся РАНЬШЕ вопроса «не смена ли это сцены».
    // Чужая вспышка поднимает нашу рамку засветкой, но свою — заметно сильнее,
    // и этот перевес (`lampGateAsymmetry` из калибровки, те же 1.5, что требует
    // эталонный вектор) решает кадр, даже когда обе рамки ушли за порог.
    // Прежде такой кадр не решался ничем: каналы стояли, а держись он дольше
    // [_commonRunLimit] — окно перестраивалось и проглатывало саму вспышку
    // (замер 20.11.2026: `aW 0.561 / aR 0.553`, обе выше порога — отсюда и
    // «не считает», и «всё в одну корзину»).
    final double gate = LampCalibration.lampGateAsymmetry;
    bool whiteYielded = spatial && redRise >= gate * whiteRise;
    bool redYielded = spatial && whiteRise >= gate * redRise;

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
        _build();
        _frames = 0;
        _commonRun = 0;
        _last = LiveReading.warmup;
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
      whiteBelowOff: !warm || whiteNet < whiteLevel * off,
      redBelowOff: !warm || redNet < redLevel * off,
      warm: warm,
    );

    // Кадр, где лампа горит, в окно НЕ попадает: иначе долгое горение поднимет
    // «пол» до собственной яркости, канал отпустит, и следующая такая же
    // вспышка не будет видна. Окно описывает только тёмное состояние.
    //
    // Кадр на потолке сенсора — то же самое запрещённое состояние, но по другой
    // причине: Y = 255 не различает «лампа горит» и «пересвечен фон», доли цвета
    // там тоже сгорают (замер: выжженный колпак wf 1.000 вошёл в окно «пола»).
    // Такие кадры в окно не пишутся ни при каком решении.
    final double clip = _config.clipLuma;
    final bool whiteClipped = frame.white.p90Luma >= clip;
    final bool redClipped = frame.red.p90Luma >= clip;
    _add(
      whiteCore: whiteCore,
      redCore: redCore,
      whiteRing: whiteRing == null ? null : whiteRingValue,
      redRing: redRing == null ? null : redRingValue,
      whiteDark: !whiteUp && !whiteClipped,
      redDark: !redUp && !redClipped,
    );
    _last = reading;
    return reading;
  }

  void _add({
    required double whiteCore,
    required double redCore,
    required double? whiteRing,
    required double? redRing,
    required bool whiteDark,
    required bool redDark,
  }) {
    if (whiteDark) {
      _whiteCore.add(whiteCore);
      if (whiteRing != null) {
        _whiteRing.add(whiteRing);
      }
    }
    if (redDark) {
      _redCore.add(redCore);
      if (redRing != null) {
        _redRing.add(redRing);
      }
    }
    _frames++;
  }

  /// Порог = шум окна × σ-множитель, но не ниже абсолютного минимума и не выше
  /// потолка: на идеально ровной сцене σ = 0, и «6σ» не защищает от пары
  /// пикселей, а на гуляющей камере «6σ» перерастает максимум подъёма и убивает
  /// канал (см. [LampConfig.referenceMaxLevel]).
  double _level(RollingFloor ref) {
    final double maxLevel = _config.referenceMaxLevel;
    final double byNoise = _config.referenceNoiseSigmas * ref.sigma;
    final double capped = byNoise > maxLevel ? maxLevel : byNoise;
    return capped > _config.referenceMinRise ? capped : _config.referenceMinRise;
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
