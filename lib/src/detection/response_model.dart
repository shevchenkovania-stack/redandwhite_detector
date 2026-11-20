import 'dart:math' as math;
import 'dart:typed_data';

import '../models/frame_features.dart';
import '../models/lamp_config.dart';
import 'lamp_calibration.dart';

/// Вектор признаков кадра для решения «какая лампа горит».
///
/// Форматов два, выбирает их [LampConfig.spatialVectors]:
///
/// * прежний — шесть чисел: доли белых и красных пикселей и яркость каждой из
///   двух РАМОК;
/// * пространственный — восемь чисел: среднее и верхний процентиль яркости
///   ЧЕТЫРЁХ измеряемых областей (ядро и кольцо каждой рамки). Цвета в нём нет
///   вовсе: оттенок пересвеченной красной лампы для сенсора белый, а вот КУДА
///   лёг свет различим всегда.
///
/// Яркость делится на 255, чтобы она и доли были в одном масштабе — иначе
/// наименьшие квадраты решались бы по одной только яркости.
///
/// Кольцо, которого в кадре нет (null), даёт в векторе нули ПО ВСЕМ своим
/// координатам — и у эталона, и у измерения. Такие координаты ничем не
/// отличаются от выкинутых: в скалярных произведениях они обнуляются, поэтому
/// недостающая область не добавляет ни веса, ни шума.
///
/// Порядок фиксирован и открыт: к вектору обращаются и калибровка, и детектор,
/// и экраны диагностики.
class LampVector {
  const LampVector({required this.spatial});

  factory LampVector.fromConfig(LampConfig config) =>
      LampVector(spatial: config.spatialVectors);

  /// Пространственная яркостная картина вместо цветовых долей.
  final bool spatial;

  static const int legacyLength = 6;
  static const int spatialLength = 8;

  int get length => spatial ? spatialLength : legacyLength;

  static const int whiteWhiteFrac = 0;
  static const int whiteRedFrac = 1;
  static const int whiteMeanY = 2;
  static const int redWhiteFrac = 3;
  static const int redRedFrac = 4;
  static const int redMeanY = 5;

  static const int whiteCoreMean = 0;
  static const int whiteCoreP90 = 1;
  static const int whiteRingMean = 2;
  static const int whiteRingP90 = 3;
  static const int redCoreMean = 4;
  static const int redCoreP90 = 5;
  static const int redRingMean = 6;
  static const int redRingP90 = 7;

  /// Вектор текущего кадра: обе рамки и оба кольца.
  Float64List of(LampFrame frame) => spatial
      ? _luma(frame.white, frame.whiteRing, frame.red, frame.redRing)
      : _legacy(frame.white, frame.red);

  Float64List ofState(CalibrationState state) => spatial
      ? _luma(state.white, state.whiteRing, state.red, state.redRing)
      : _legacy(state.white, state.red);

  /// σ признаков состояния — тот же вектор, только из отклонений.
  Float64List ofSigma(CalibrationState state) => spatial
      ? _luma(state.whiteSigma, state.whiteRingSigma, state.redSigma, state.redRingSigma)
      : _legacy(state.whiteSigma, state.redSigma);

  /// Измеренный отклик лампы: чем состояние «лампа горит» отличается от фона.
  Float64List ofResponse(CalibrationState lit, CalibrationState background) =>
      subtract(ofState(lit), ofState(background));

  static Float64List _legacy(FrameFeatures white, FrameFeatures red) =>
      Float64List.fromList(<double>[
        white.whiteFrac,
        white.redFrac,
        white.meanY / 255.0,
        red.whiteFrac,
        red.redFrac,
        red.meanY / 255.0,
      ]);

  /// Четыре области × два числа яркости. Отсутствующее кольцо — два нуля.
  static Float64List _luma(
    FrameFeatures whiteCore,
    FrameFeatures? whiteRing,
    FrameFeatures redCore,
    FrameFeatures? redRing,
  ) {
    return Float64List.fromList(<double>[
      whiteCore.meanY / 255.0,
      whiteCore.p90Luma / 255.0,
      (whiteRing?.meanY ?? 0) / 255.0,
      (whiteRing?.p90Luma ?? 0) / 255.0,
      redCore.meanY / 255.0,
      redCore.p90Luma / 255.0,
      (redRing?.meanY ?? 0) / 255.0,
      (redRing?.p90Luma ?? 0) / 255.0,
    ]);
  }

  Float64List subtract(Float64List a, Float64List b) {
    final Float64List out = Float64List(length);
    for (int i = 0; i < length; i++) {
      out[i] = a[i] - b[i];
    }
    return out;
  }

  double dot(Float64List a, Float64List b) {
    double sum = 0;
    for (int i = 0; i < length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  double norm(Float64List a) => math.sqrt(dot(a, a));

  /// Имя координаты для сообщения об ошибке: оператор обязан понять, какой
  /// признак шумит и какую область из-за этого нечем мерить.
  String name(int index) => spatial
      ? switch (index) {
          whiteCoreMean => 'яркость ядра белой рамки',
          whiteCoreP90 => 'p90 ядра белой рамки',
          whiteRingMean => 'яркость кольца белой рамки',
          whiteRingP90 => 'p90 кольца белой рамки',
          redCoreMean => 'яркость ядра красной рамки',
          redCoreP90 => 'p90 ядра красной рамки',
          redRingMean => 'яркость кольца красной рамки',
          redRingP90 => 'p90 кольца красной рамки',
          _ => 'признак #$index',
        }
      : switch (index) {
          whiteWhiteFrac => 'whiteFrac белой рамки',
          whiteRedFrac => 'redFrac белой рамки',
          whiteMeanY => 'яркость белой рамки',
          redWhiteFrac => 'whiteFrac красной рамки',
          redRedFrac => 'redFrac красной рамки',
          redMeanY => 'яркость красной рамки',
          _ => 'признак #$index',
        };
}

/// Результат расклада одного кадра на две измеренные лампы.
class LampResponse {
  const LampResponse({
    required this.white,
    required this.red,
    required this.change,
    required this.explained,
    required this.residual,
  });

  /// Амплитуды в долях измеренного отклика: 1.0 = «рамки изменились ровно так,
  /// как на калибровке, когда эту лампу держали зажжённой».
  final double white;
  final double red;

  /// ||d|| — насколько кадр вообще ушёл от фона.
  final double change;

  /// ||aW·tW + aR·tR|| — какая часть ухода объясняется двумя лампами.
  final double explained;

  /// Необъяснённый остаток: рука, тряска, засветка, «не похоже ни на одну».
  final double residual;

  /// Картина изменения похожа на лампы больше, чем на помеху: объяснённая часть
  /// не меньше остатка. Отдельного порога не требует — это сравнение двух
  /// половин одного числа.
  bool get looksLikeLamps => explained >= residual;

  @override
  String toString() =>
      'LampResponse(W=${white.toStringAsFixed(2)}, R=${red.toStringAsFixed(2)}, '
      'Δ=${change.toStringAsFixed(3)}, explained=${explained.toStringAsFixed(3)}, '
      'residual=${residual.toStringAsFixed(3)})';
}

/// Измеренная модель отклика: два эталона, набранные на калибровке, и арифметика
/// над ними.
///
/// Никакого «цвета пикселя» в решении нет: кадр описывается изменением
/// измеряемых областей и раскладывается на два эталона — «горит белая» и
/// «горит красная» — методом наименьших квадратов. Система из шести (в
/// пространственном векторе — восьми) уравнений с двумя неизвестными
/// переопределена, а решение остаётся детерминированной арифметикой: 2×2
/// матрица Грама обращается явно, итераций здесь нет. Размер здесь не важен
/// вовсе — важна только размерность вектора, которым собраны эталоны.
class LampResponseModel {
  factory LampResponseModel(LampBaseline baseline, {required LampConfig config}) {
    final LampVector v = LampVector.fromConfig(config);
    return LampResponseModel._(
      baseline: baseline,
      vector: v,
      background: v.ofState(baseline.background),
      noise: v.ofSigma(baseline.background),
      whiteTemplate: v.ofResponse(baseline.whiteOn, baseline.background),
      redTemplate: v.ofResponse(baseline.redOn, baseline.background),
      whiteNoise: v.ofSigma(baseline.whiteOn),
      redNoise: v.ofSigma(baseline.redOn),
    );
  }

  LampResponseModel._({
    required this.baseline,
    required this.vector,
    required this.background,
    required this.noise,
    required this.whiteTemplate,
    required this.redTemplate,
    required Float64List whiteNoise,
    required Float64List redNoise,
  }) {
    noiseNorm = vector.norm(noise);
    whiteResponse = vector.norm(whiteTemplate);
    redResponse = vector.norm(redTemplate);
    crosstalk = whiteResponse * redResponse == 0
        ? 1
        : vector.dot(whiteTemplate, redTemplate).abs() / (whiteResponse * redResponse);
    _gww = vector.dot(whiteTemplate, whiteTemplate);
    _gwr = vector.dot(whiteTemplate, redTemplate);
    _grr = vector.dot(redTemplate, redTemplate);
    _det = _gww * _grr - _gwr * _gwr;
    // Расклад годен, если эталоны ненулевые и не сливаются в один: при
    // cos φ → 1 определитель уходит в ноль и амплитуды начинают шуметь.
    _solvable = _det > _minDeterminant && _gww > 0 && _grr > 0;

    whiteSeparationSigmas = _separation(whiteResponse, whiteNoise);
    redSeparationSigmas = _separation(redResponse, redNoise);
    whiteAmplitudeNoise = _solvable ? _amplitudeNoise(white: true) : double.infinity;
    redAmplitudeNoise = _solvable ? _amplitudeNoise(white: false) : double.infinity;
    isValid = _solvable;
  }

  /// Калибровка, из которой собраны эталоны.
  final LampBaseline baseline;

  /// Каким вектором измерена эта модель: шести- или восьмимерным. Нужен и
  /// диагностике, чтобы подписывать координаты правильными именами.
  final LampVector vector;

  /// Вектор фона (среднее состояние «обе погашены») и σ его признаков.
  final Float64List background;
  final Float64List noise;

  /// Эталон «горит белая минус фон» и «горит красная минус фон».
  final Float64List whiteTemplate;
  final Float64List redTemplate;

  /// ||σ|| — шум фона в единицах вектора: порог «что-то вообще изменилось».
  late final double noiseNorm;

  /// Длина каждого эталона = полный измеренный отклик в единицах вектора.
  late final double whiteResponse;
  late final double redResponse;

  /// Насколько эталоны похожи друг на друга: 0 = картины изменения совершенно
  /// разные, 1 = неразличимы.
  late final double crosstalk;

  /// Во сколько раз отклик больше шума своих состояний. `infinity`, если шум
  /// ровно нулевой (синтетика, идеальный стенд).
  late final double whiteSeparationSigmas;
  late final double redSeparationSigmas;

  /// σ амплитуды в долях отклика: насколько нельзя доверять числу «доля лампы»
  /// в одном кадре. `infinity`, когда расклад неустойчив.
  late final double whiteAmplitudeNoise;
  late final double redAmplitudeNoise;

  /// Расклад осмыслен: эталоны ненулевые и не сливаются в один.
  late final bool isValid;

  late final double _gww;
  late final double _gwr;
  late final double _grr;
  late final double _det;
  late final bool _solvable;

  /// Число σ, ниже которого шум фона не пускает срабатывание. Прежде было
  /// параметром конфига (`noiseSigmas`); теперь σ измеряется на калибровке, а
  /// множитель — соглашение, которое под конкретную лампу не подбирают.
  static const double noiseSigmas = 6;

  /// Относительный порог определителя Грама: ниже него эталоны сливаются, и
  /// расклад выдаёт мусор вместо амплитуд.
  double get _minDeterminant => 1e-6 * _gww * _grr;

  double _separation(double response, Float64List stateSigma) {
    double sum = 0;
    for (int i = 0; i < vector.length; i++) {
      // Шум разности двух состояний — корень из суммы их дисперсий.
      final double s = math.sqrt(noise[i] * noise[i] + stateSigma[i] * stateSigma[i]);
      sum += s * s;
    }
    final double sigmaNorm = math.sqrt(sum);
    return sigmaNorm == 0 ? double.infinity : response / sigmaNorm;
  }

  /// σ(aW): aW = Σ w_j·d_j, где w — строка обратной матрицы Грама, умноженная
  /// на эталон, поэтому σ(aW)² = Σ w_j²·σ_j².
  double _amplitudeNoise({required bool white}) {
    final Float64List own = white ? whiteTemplate : redTemplate;
    final Float64List other = white ? redTemplate : whiteTemplate;
    final double gOwn = white ? _grr : _gww;
    double sum = 0;
    for (int i = 0; i < vector.length; i++) {
      final double w = (gOwn * own[i] - _gwr * other[i]) / _det;
      sum += w * w * noise[i] * noise[i];
    }
    return math.sqrt(sum);
  }

  /// Почему калибровку нельзя использовать (null = всё в порядке). Сообщение
  /// обязано называть лампу: оператору важно, на каком шаге он её не зажёг или
  /// не попал рамкой.
  String? invalidReason(double minSeparation) => _invalid(minSeparation)?.reason;

  /// Какой шаг нужно переснять из-за той же причины. Немой или тонущий в шуме
  /// канал — это шаг его лампы, а не всегда последний: переснимать красную,
  /// когда белая не дала отклика, значит гонять оператора по кругу.
  CalibrationStep failingStep(double minSeparation) =>
      _invalid(minSeparation)?.step ?? CalibrationStep.redOn;

  ({String reason, CalibrationStep step})? _invalid(double minSeparation) {
    if (whiteResponse == 0) {
      return (
        reason: 'белая лампа не изменила ни одну рамку (шаг 2): отклик равен нулю',
        step: CalibrationStep.whiteOn,
      );
    }
    if (redResponse == 0) {
      return (
        reason: 'красная лампа не изменила ни одну рамку (шаг 3): отклик равен нулю',
        step: CalibrationStep.redOn,
      );
    }
    if (!isValid) {
      return (
        reason:
            'обе лампы меняют рамки одинаково (перетекание '
            '${(crosstalk * 100).toStringAsFixed(0)}%), разделить их нечем',
        step: CalibrationStep.redOn,
      );
    }
    if (whiteSeparationSigmas < minSeparation) {
      return (
        reason:
            'белая лампа едва отличается от фона (шаг 2): отклик '
            '${whiteSeparationSigmas.toStringAsFixed(1)}σ при минимуме '
            '${minSeparation.toStringAsFixed(0)}σ',
        step: CalibrationStep.whiteOn,
      );
    }
    if (redSeparationSigmas < minSeparation) {
      return (
        reason:
            'красная лампа едва отличается от фона (шаг 3): отклик '
            '${redSeparationSigmas.toStringAsFixed(1)}σ при минимуме '
            '${minSeparation.toStringAsFixed(0)}σ',
        step: CalibrationStep.redOn,
      );
    }
    final double worst = math.max(whiteAmplitudeNoise, redAmplitudeNoise);
    if (worst > 1 / minSeparation) {
      return (
        reason:
            'шум сопоставим с откликом: амплитуда дрожит на '
            '${(worst * 100).toStringAsFixed(0)}% отклика при допустимых '
            '${(100 / minSeparation).toStringAsFixed(0)}%',
        step: CalibrationStep.redOn,
      );
    }
    return null;
  }

  /// ON-уровень каждой лампы в долях измеренного отклика: не меньше
  /// [hitFraction] и не ниже уровня шума фона.
  double whiteOnLevel(double hitFraction) =>
      math.max(hitFraction, noiseSigmas * whiteAmplitudeNoise);

  double redOnLevel(double hitFraction) =>
      math.max(hitFraction, noiseSigmas * redAmplitudeNoise);

  /// Раскладывает изменение кадра на две амплитуды.
  LampResponse unmix(LampFrame frame) {
    final Float64List d = vector.subtract(vector.of(frame), background);
    final double changeSq = vector.dot(d, d);
    final double change = math.sqrt(changeSq);
    if (!_solvable || _det <= 0) {
      return LampResponse(
        white: 0,
        red: 0,
        change: change,
        explained: 0,
        residual: change,
      );
    }
    final double bWhite = vector.dot(whiteTemplate, d);
    final double bRed = vector.dot(redTemplate, d);
    final double aWhite = (_grr * bWhite - _gwr * bRed) / _det;
    final double aRed = (_gww * bRed - _gwr * bWhite) / _det;
    // Объяснённая часть = ||aW·tW + aR·tR||² = aW·bW + aR·bR: остаток
    // ортогонален плоскости эталонов, поэтому работает Пифагор. Отрицательной
    // она быть не может, но округление на вырожденном входе даёт −1e-17.
    final double explainedSq = math.max(0.0, aWhite * bWhite + aRed * bRed);
    final double residualSq = math.max(0.0, changeSq - explainedSq);
    return LampResponse(
      white: aWhite,
      red: aRed,
      change: change,
      explained: math.sqrt(explainedSq),
      residual: math.sqrt(residualSq),
    );
  }
}
