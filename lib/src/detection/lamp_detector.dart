import 'dart:math' as math;

import '../models/frame_features.dart';
import '../models/hit_event.dart';
import '../models/lamp_config.dart';
import 'hsv_reference.dart';
import 'lamp_calibration.dart';
import 'live_reference.dart';
import 'response_model.dart';

/// Результат оценки одного кадра детектором.
///
/// [whiteAmplitude] и [redAmplitude] — доли измеренного отклика каждой лампы
/// (1.0 = «рамки изменились так же, как на калибровке с горящей лампой»).
/// [residual] — то, что ни одна лампа не объясняет.
class LampEvaluation {
  const LampEvaluation({
    required this.timestamp,
    required this.whiteAmplitude,
    required this.redAmplitude,
    required this.change,
    required this.explained,
    required this.residual,
    required this.unexplained,
    required this.whiteOn,
    required this.redOn,
    required this.whiteOff,
    required this.redOff,
    required this.whiteLit,
    required this.redLit,
    required this.ambiguous,
    required this.ambiguousWinner,
    required this.whiteOnCandidateAt,
    required this.redOnCandidateAt,
    this.whiteNet = 0,
    this.redNet = 0,
    this.whiteDarkMs = 0,
    this.redDarkMs = 0,
  });

  final DateTime timestamp;
  final double whiteAmplitude;
  final double redAmplitude;

  /// ||d||: насколько кадр ушёл от фона, сколько из этого объясняют две лампы,
  /// а сколько остаётся необъяснённым.
  final double change;

  /// ||aW·tW + aR·tR||: измеренная «похожесть на лампы» в тех же единицах, что
  /// и [change]. Отношение explained/change — доля ухода, объяснённой лампами.
  final double explained;
  final double residual;

  /// Кадр «не похоже ни на одну лампу»: изменение большое, а раскладывается
  /// хуже, чем остаётся необъяснённым. Это рука, тряска, засветка или смена
  /// сцены — событие по такому кадру не выдаётся.
  final bool unexplained;

  /// Подтверждённое включение (N подряд кадров выше ON-уровня) этим кадром.
  final bool whiteOn;
  final bool redOn;

  /// Подтверждённое выключение (M подряд кадров ниже OFF-уровня) этим кадром.
  final bool whiteOff;
  final bool redOff;

  /// Текущее состояние гистерезиса каждой лампы.
  final bool whiteLit;
  final bool redLit;

  /// Подъём своей рамки без общего для обеих рамок света — то, по чему
  /// гистерезис решил о выключении. Только в режиме живого отсчёта (в режиме
  /// эталонов общего не бывает: там вычитается измеренный фон).
  final double whiteNet;
  final double redNet;

  /// Кадр, в котором обе амплитуды выше своего ON-уровня одновременно.
  final bool ambiguous;
  final HitColor? ambiguousWinner;

  /// Время кадра, где лампа впервые стала кандидатом ON в текущей серии.
  /// Именно оно попадает в HitEvent.detectedAt.
  final DateTime? whiteOnCandidateAt;
  final DateTime? redOnCandidateAt;

  /// Сколько миллисекунд длится текущий интервал «не выше ON-уровня» каждой
  /// лампы — и гашение, и провал внутри горения. Единственное число, по которому
  /// на стенде подбирают [LampConfig.offConfirmMs]: провалы внутри одного горения
  /// должны быть короче него, паузы между ударами — длиннее.
  final int whiteDarkMs;
  final int redDarkMs;
}

/// Гистерезис одной лампы: подтверждение включения/выключения.
class _LampTracker {
  bool lit = false;
  int _onRun = 0;

  /// Сколько кадров ТЕКУЩЕГО провала ушли ниже OFF-уровня. Обнуляется только
  /// когда лампа снова поднялась выше ON — см. [step].
  int _offRun = 0;
  DateTime? _onCandidateAt;

  /// Начало текущего провала ниже OFF-уровня и его длительность в мс. Нужны
  /// потому, что одно физическое горение — волна: амплитуда падает внутри
  /// вспышки, и правило, меряющее выключение только числом кадров, закрывает
  /// событие посреди удара, а следующий кадр открывает второй раз.
  DateTime? _darkSince;
  int _darkMs = 0;

  /// Наименьший подъём над «полом» за текущий провал. Это то, чем провал
  /// внутри горения отличается от настоящего гашения: выключенная лампа падает
  /// к нулю (её совсем не видно), волна же проседает, но лампу не гасит.
  double _darkMin = double.infinity;

  /// Возвращает [becameOn]/[becameOff] — подтверждённые переходы этим кадром.
  ({bool becameOn, bool becameOff}) step({
    required bool aboveOn,
    required bool belowOff,
    required double amplitude,
    required DateTime timestamp,
    required int onConfirmFrames,
    required int offConfirmFrames,
    required int offConfirmMs,
    required double floorAmplitude,
    bool valid = true,
  }) {
    // Нет достоверного отсчёта — время и счётчики не идут. В частности, прогрев
    // не является провалом до OFF и не может переоткрыть одно и то же горение.
    if (!valid) {
      return (becameOn: false, becameOff: false);
    }
    if (aboveOn) {
      _onRun++;
      _offRun = 0;
      _resetDark();
      _onCandidateAt ??= timestamp;
    } else {
      // Кадр НЕ выше ON-уровня. Это и настоящее гашение, и провал внутри
      // одного горения — интервал считается от первого такого кадра и не
      // прерывается гистерезисной зоной, иначе волна вспышки дробилась бы на
      // несколько коротких провалов и каждый мог бы закрыться отдельно.
      // Отсчёт от первого обработанного кадра — НИЖНЯЯ граница настоящего
      // провала: сигнал упал где-то между ним и прежним кадром. Занижать окно
      // подтверждения нельзя, а завысить его означало бы съесть паузу между
      // двумя ударами.
      _darkSince ??= timestamp;
      _darkMs = timestamp.difference(_darkSince!).inMilliseconds;
      if (amplitude < _darkMin) {
        _darkMin = amplitude;
      }
      // Кадры ниже OFF-уровня копятся с НАЧАЛА провала, а не идут строго
      // подряд. Прежнее «подряд» было ловушкой: канал, который чужая лампа
      // держит в гистерезисной зоне (между OFF и ON), сбрасывался в ноль каждой
      // такой рамкой, гашение не подтверждалось никогда, и канал залипал в
      // «горит» до перезапуска — а все события уходили в живую вторую корзину.
      // Физическую длину провала по-прежнему меряют [offConfirmMs] и глубина
      // [floorAmplitude], а не счётчик подряд.
      if (belowOff) {
        _offRun++;
      }
      _onRun = 0;
      _onCandidateAt = null;
    }

    bool becameOn = false;
    bool becameOff = false;
    if (!lit && _onRun >= onConfirmFrames) {
      lit = true;
      becameOn = true;
      _resetDark();
    } else if (lit &&
        _offRun >= offConfirmFrames &&
        // Гашение подтверждается, только если провал либо УШЁЛ К ПОЛУ (лампу
        // не стало видно — значит, её выключили), либо ТЯНЕТСЯ достаточно
        // долго ([offConfirmMs]), чтобы быть паузой между ударами, а не
        // просадкой внутри одного. Кадровое условие остаётся нижней границей:
        // одному мусорному кадру не верим ни в каком случае.
        (_darkMin <= floorAmplitude || _darkMs >= offConfirmMs)) {
      lit = false;
      becameOff = true;
      // Провал НЕ обнуляется: он ещё длится, и именно его полная длительность
      // нужна, чтобы по записи отличить паузу между ударами от внутриударной
      // волны.
      _offRun = 0;
    }
    return (becameOn: becameOn, becameOff: becameOff);
  }

  DateTime? get onCandidate => _onCandidateAt;

  /// Принудительно погасить лампу: другая лампа доказанно включилась, а по
  /// спецификации две лампы одновременно не горят. Состояние сбрасывается
  /// целиком, чтобы следующее включение этой лампы считалось заново.
  void forceOff() {
    lit = false;
    _onRun = 0;
    _offRun = 0;
    _onCandidateAt = null;
    _resetDark();
  }

  /// Сколько миллисекунд длится текущий интервал «не выше ON-уровня» (0, если
  /// его нет). По этому числу на записи и разбирают, где провал внутри одного
  /// горения, а где настоящая пауза между ударами.
  int get darkMs => _darkMs;

  void _resetDark() {
    _darkSince = null;
    _darkMs = 0;
    _darkMin = double.infinity;
  }

  void reset() {
    lit = false;
    _onRun = 0;
    _offRun = 0;
    _onCandidateAt = null;
    _resetDark();
  }
}

/// Оценка «какая лампа горит» по изменению обеих рамок относительно измеренных
/// эталонов, плюс автомат гистерезиса на обе лампы.
///
/// Порогов «как ярко» больше нет: кадр раскладывается на два эталона, набранные
/// на калибровке, и сравнивается с [LampConfig.hitFraction] — долей того, что
/// лампа показала, когда её держали зажжённой. Вся арифметика — в
/// [LampResponseModel], отбор и проверка состояний — в [LampCalibration].
///
/// При `config.liveReference` тот же гистерезис работает от живого отсчёта
/// ([LiveReference]): «ноль» берётся из последних кадров, а калибровка остаётся
/// самопроверкой «рамка видит лампу».
class LampDetector {
  LampDetector(this._config)
    : _calibration = LampCalibration(_config),
      _live = LiveReference(_config),
      _hsv = HsvReference(_config);

  /// Пороги можно менять на лету (подбор по записанным CSV).
  LampConfig get config => _config;
  set config(LampConfig value) {
    // Вектор признаков с тех пор один (яркость четырёх областей), и конфиг на
    // него не влияет, поэтому пересобирать модель здесь нечего: пороги
    // уходят калибровке и живому отсчёту.
    //
    // Смена СПОСОБА решения окна сбрасывает: «пол» и порог, набранные в
    // яркости, и «пол», набранный в долях цветных пикселей, — разные величины,
    // и сравнивать одно с другим нельзя.
    final bool modeChanged =
        value.liveReference != _config.liveReference ||
        value.hsvReference != _config.hsvReference;
    _config = value;
    _calibration.config = value;
    _live.config = value;
    _hsv.config = value;
    _applyHsvSignature();
    if (modeChanged) {
      resetTracking();
    }
  }

  LampConfig _config;

  final LampCalibration _calibration;
  final LiveReference _live;
  final HsvReference _hsv;
  final _LampTracker _white = _LampTracker();
  final _LampTracker _red = _LampTracker();

  LampBaseline? _baseline;
  LampResponseModel? _model;
  int _ambiguousFrames = 0;
  int _unexplainedFrames = 0;
  int _doubleBasketFrames = 0;

  LampBaseline? get baseline => _baseline;

  /// Измеренная модель отклика. Null до завершённой калибровки.
  LampResponseModel? get model => _model;

  bool get isCalibrated => _model?.isValid ?? false;

  /// Есть чем решать: живой отсчёт и HSV-отсчёт работают сразу, режим
  /// эталонов — только после калибровки. Сессия спрашивает это вместо
  /// [isCalibrated].
  bool get canEvaluate =>
      _config.hsvReference || _config.liveReference || isCalibrated;

  /// Сколько кадров подряд были неоднозначными (обе амплитуды выше своего уровня).
  int get ambiguousFrames => _ambiguousFrames;

  /// Сколько кадров не похожи ни на одну лампу: рука, тряска, засветка.
  int get unexplainedFrames => _unexplainedFrames;

  /// Сколько раз один кадр просился сразу в обе корзины и был отдан одной
  /// ([_oneBasket]). Ноль после калибровки — правило не пригодилось; растёт на
  /// плохих рамках и на засветке чужой лампы, и именно по нему видно, что
  /// удвоение счёта ловится, а не проходит.
  int get doubleBasketFrames => _doubleBasketFrames;

  /// Восстановление калибровки из настроек.
  void setBaseline(LampBaseline baseline) {
    _baseline = baseline;
    _model = LampResponseModel(baseline);
    _applyHsvSignature();
    resetTracking();
  }

  /// Калибровки нет — детекция стоит на нуле, а не работает «вслепую».
  void clearBaseline() {
    _baseline = null;
    _model = null;
    _applyHsvSignature();
    resetTracking();
  }

  /// Выучить у калибровки правило именования вспышек.
  ///
  /// Null в трёх случаях: калибровки нет, HSV-отсчёт выключен или флаг
  /// именования выключен — и тогда остаётся прежнее правило с вето по чужому
  /// каналу. Отдельно null, когда три состояния не разделяются ни по одному из
  /// 16 признаков ([LampConfig.hsvSignatureMinSigmas] σ): например, на
  /// записях iPhone красная лампа выбита в белый, и учиться там нечему.
  /// Держать детектор на выученном правиле в таком случае значило бы называть
  /// лампы монеткой.
  void _applyHsvSignature() {
    final LampBaseline? base = _baseline;
    _hsv.signature =
        base == null || !_config.hsvReference || !_config.hsvSignatureNaming
        ? null
        : HsvSignature.learn(
            base,
            minSeparation: _config.hsvSignatureMinSigmas,
          );
  }

  /// Сброс гистерезиса и счётчиков (новая сессия, старт, калибровка).
  void resetTracking() {
    _white.reset();
    _red.reset();
    _live.reset();
    _hsv.reset();
    _ambiguousFrames = 0;
    _unexplainedFrames = 0;
    _doubleBasketFrames = 0;
  }

  /// Одна вспышка — одна корзина.
  ///
  /// Лампы загораются по очереди (спецификация стенда, слово заказчика
  /// 24.11.2026), поэтому событие не имеет права появиться в обеих корзинах:
  /// если засчитана белая, красная не получает ничего. Делается ровно две
  /// вещи, обе — над уже подтверждёнными переходами, чтобы не менять пороги:
  ///
  ///  * оба канала подтвердились в одном кадре — остаётся победитель
  ///    ([winner], а если он не вычислен — канал с большим подъёмом),
  ///    проигравший гасится через [forceOff] и случай считается в
  ///    [doubleBasketFrames];
  ///  * одна лампа включилась, а другая всё ещё числится горящей — вторая
  ///    гасится принудительно: её залипший «горит» съел бы её следующую
  ///    вспышку.
  ///
  /// Реальные события это не съедает: у вспышки есть пауза, за которую
  /// проигравший канал успевает упасть к «полу» и набрать свои кадры
  /// подтверждения заново.
  ({bool redOff, bool redOn, bool whiteOff, bool whiteOn}) _oneBasket({
    required bool whiteOn,
    required bool redOn,
    required bool whiteOff,
    required bool redOff,
    required HitColor? winner,
    required double whiteAmp,
    required double redAmp,
  }) {
    if (whiteOn && redOn) {
      _doubleBasketFrames++;
      final HitColor keep =
          winner ?? (whiteAmp >= redAmp ? HitColor.white : HitColor.red);
      if (keep == HitColor.white) {
        _red.forceOff();
        return (whiteOn: true, redOn: false, whiteOff: whiteOff, redOff: true);
      }
      _white.forceOff();
      return (whiteOn: false, redOn: true, whiteOff: true, redOff: redOff);
    }
    if (whiteOn && _red.lit) {
      _red.forceOff();
      redOff = true;
    } else if (redOn && _white.lit) {
      _white.forceOff();
      whiteOff = true;
    }
    return (whiteOn: whiteOn, redOn: redOn, whiteOff: whiteOff, redOff: redOff);
  }

  /// Шаг, который калибровка набирает сейчас.
  CalibrationStep get calibrationStep => _calibration.step;

  /// Шаги, состояния которых уже набраны с начала текущей калибровки.
  List<CalibrationStep> get completedCalibrationSteps =>
      _calibration.completedSteps;

  /// Прогресс текущего шага калибровки.
  CalibrationProgress get calibrationProgress => _calibration.progress;

  /// Начать пошаговую калибровку с нуля: фон → белая → красная. Прежняя
  /// калибровка при этом сбрасывается, и до третьего шага детектор не считает
  /// события — иначе он решал бы по эталонам другой сцены.
  ///
  /// Единственный способ «калибровки нет»: метод стирает и собранные состояния,
  /// и базу (`clearBaseline`). Отдельный `clearCalibration`, трогавший только
  /// набор, был удалён: им пользовались как сбросом, и калибровка переживала
  /// его.
  void startCalibration() {
    _calibration.reset();
    clearBaseline();
  }

  /// Забыть недобранный текущий шаг калибровки, сохранив принятые состояния.
  void discardCalibrationStep() => _calibration.discardCurrentStep();

  /// Встать на шаг `step`, чтобы снять его заново: его собственное состояние и
  /// всё, что снято позже, стирается. Без этого калибровка была бы только
  /// «всё набором с первого шага», а кнопки «1 ФОН / 2 БЕЛАЯ / 3 КРАСНАЯ»
  /// требуют, чтобы любой шаг снимался сам по себе.
  void goToCalibrationStep(CalibrationStep step) => _calibration.goToStep(step);

  /// Подать калибровке уже измеренные состояния, чтобы переснять по кнопке
  /// ровно один шаг: фон и белая остаются прежними, новой пишется только
  /// переснимаемая ячейка.
  void seedCalibration(LampBaseline baseline) =>
      _calibration.adoptStates(baseline);

  /// Зажглась ли лампа шага `step` на этом кадре — по «своей» доле пикселей
  /// относительно набранного фона. Нужен пошаговой калибровке, чтобы не собрать
  /// кадры лампы раньше, чем её включили.
  bool lampAppeared(LampFrame frame, CalibrationStep step) =>
      _calibration.lampAppeared(frame, step);

  /// То же для подсказки: пока фон текущего прогона не набран, сравнивается с
  /// ПРЕЖНИМ фоном ([setCalibrationReference]). Решения о наборе кадров по
  /// этому признаку не принимается — старый эталон может относиться к другой
  /// сцене.
  bool lampLikelyLit(LampFrame frame, CalibrationStep step) =>
      _calibration.lampLikelyLit(frame, step);

  /// Фон прежней калибровки, на который можно опереться подсказкой до конца
  /// текущего прогона. Null — подсказка обязана молчать.
  void setCalibrationReference(LampBaseline? baseline) =>
      _calibration.backgroundReference = baseline?.background;

  /// Кадр текущего шага калибровки. Возвращает отчёт о завершённом шаге (на
  /// последнем — с готовым baseline, который детектор сразу принимает), иначе
  /// null. Бросает [CalibrationException], если шаг не прошёл проверку.
  CalibrationReport? addCalibrationFrame(LampFrame frame) {
    final CalibrationReport? report = _calibration.addFrame(frame);
    final LampBaseline? baseline = report?.baseline;
    if (baseline != null) {
      setBaseline(baseline);
    }
    return report;
  }

  /// ON-уровень каждой лампы в долях измеренного отклика. Null до калибровки —
  /// экраны обязаны показывать именно их, а не [LampConfig.hitFraction]:
  /// при шумной калибровке порог выше. В режиме живого и HSV-отсчёта — порог из
  /// шума последних кадров, в тех же единицах, что и амплитуда.
  double? get whiteOnLevel => _level(white: true);
  double? get redOnLevel => _level(white: false);

  /// Порог включения одной лампы в том режиме, который сейчас включён. Три
  /// способа решения считают порог в разных единицах (доля отклика, яркость,
  /// доля цветных пикселей), поэтому и отдавать наружу каждое число обязан
  /// ведущий способ, а не общее по всем.
  double? _level({required bool white}) {
    if (_config.hsvReference) {
      final LiveReading reading = _hsv.last;
      return _hsv.hasReading
          ? (white ? reading.whiteLevel : reading.redLevel)
          : null;
    }
    if (_config.liveReference) {
      return _live.hasReading
          ? (white ? _live.last.whiteLevel : _live.last.redLevel)
          : null;
    }
    return white
        ? _model?.whiteOnLevel(config.hitFraction)
        : _model?.redOnLevel(config.hitFraction);
  }

  /// Сколько реальных значений ещё нужно, чтобы окна набрались. Ноль —
  /// решения уже принимаются. Отдаётся число ведущего сейчас способа: окна
  /// живого и HSV-отсчёта набираются независимо и по разным признакам.
  int get liveWarmupLeft =>
      _config.hsvReference ? _hsv.warmupLeft : _live.warmupLeft;

  /// Количество значений, «пол», sigma и причина последнего сброса для LAMPDBG.
  String get liveDebugTag =>
      _config.hsvReference ? _hsv.debugTag : _live.debugTag;

  /// Решение и состояние окон именно последнего оценённого кадра для CSV.
  LiveReading get liveReading => _config.hsvReference ? _hsv.last : _live.last;
  LiveReferenceDiagnostics get liveDiagnostics =>
      _config.hsvReference ? _hsv.diagnostics : _live.diagnostics;

  LampEvaluation evaluate(LampFrame frame) {
    if (_config.hsvReference) {
      return _evaluateHsv(frame);
    }
    if (_config.liveReference) {
      return _evaluateLive(frame);
    }

    final LampResponseModel? model = _model;
    if (model == null || !model.isValid) {
      throw StateError(
        'Детектор не откалиброван: нужна калибровка в три шага '
        '(фон → белая горит → красная горит)',
      );
    }

    final LampResponse response = model.unmix(frame);
    final double whiteOn = model.whiteOnLevel(config.hitFraction);
    final double redOn = model.redOnLevel(config.hitFraction);

    // Кадр «не похоже ни на одну лампу»: остаток больше объяснённой части И
    // больше шума фона. Такие кадры не двигают ни один канал (ни ON, ни OFF —
    // гистерезисная зона), но видны отдельным числом в диагностике.
    final bool lampLike = response.looksLikeLamps;
    final bool unexplained = !lampLike && response.residual > model.noiseNorm;
    if (unexplained) {
      _unexplainedFrames++;
    }

    final bool whiteAboveOn = lampLike && response.white >= whiteOn;
    final bool redAboveOn = lampLike && response.red >= redOn;
    final bool whiteBelowOff =
        lampLike && response.white < whiteOn * config.offRatio;
    final bool redBelowOff = lampLike && response.red < redOn * config.offRatio;

    // Обе амплитуды выше своего уровня в одном кадре. По спецификации стенда
    // лампы одновременно НЕ загораются, значит такой кадр — симптом: переход
    // «одна погасла, другая включилась» попал в один кадр экспозиции, либо
    // засветка/наводка. Слово заказчика 25.11.2026: в две корзины такое
    // событие не кладётся — если посчитана белая, красная не получает ничего,
    // поэтому проигравший канал до гистерезиса не доходит ([_oneBasket]).
    // Раньше победитель только писался в диагностику, а два трекера шли
    // независимо и один вспышка давала два удара.
    final bool ambiguous = whiteAboveOn && redAboveOn;
    HitColor? winner;
    if (ambiguous) {
      _ambiguousFrames++;
      winner = response.white / whiteOn >= response.red / redOn
          ? HitColor.white
          : HitColor.red;
    }
    final bool whiteVeto =
        whiteAboveOn && (!ambiguous || winner == HitColor.white);
    final bool redVeto = redAboveOn && (!ambiguous || winner == HitColor.red);

    final ({bool becameOn, bool becameOff}) whiteStep = _white.step(
      aboveOn: whiteVeto,
      belowOff: whiteBelowOff,
      amplitude: response.white,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
      offConfirmMs: config.offConfirmMs,
      floorAmplitude: config.referenceMinRise,
    );
    final ({bool becameOn, bool becameOff}) redStep = _red.step(
      aboveOn: redVeto,
      belowOff: redBelowOff,
      amplitude: response.red,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
      offConfirmMs: config.offConfirmMs,
      floorAmplitude: config.referenceMinRise,
    );

    // Эталоны и фон после калибровки НЕ меняются никогда. Адаптивное скользящее
    // среднее (бывший baselineAlpha) было проверено живьём: фон переписывался
    // за ~10 секунд и «впитывал» вспышки (base white 0.107 → 0.235), из-за чего
    // пороги ездили вместе с ним, а на плохо наведённых рамках дрейф шёл
    // непрерывно. Перестройка фона — только ручная «Калибровка».
    final ({bool redOff, bool redOn, bool whiteOff, bool whiteOn}) basket =
        _oneBasket(
          whiteOn: whiteStep.becameOn,
          redOn: redStep.becameOn,
          whiteOff: whiteStep.becameOff,
          redOff: redStep.becameOff,
          winner: winner,
          whiteAmp: response.white,
          redAmp: response.red,
        );

    return LampEvaluation(
      timestamp: frame.timestamp,
      whiteAmplitude: response.white,
      redAmplitude: response.red,
      change: response.change,
      explained: response.explained,
      residual: response.residual,
      unexplained: unexplained,
      whiteOn: basket.whiteOn,
      redOn: basket.redOn,
      whiteOff: basket.whiteOff,
      redOff: basket.redOff,
      whiteLit: _white.lit,
      redLit: _red.lit,
      ambiguous: ambiguous,
      ambiguousWinner: winner,
      whiteOnCandidateAt: _white.onCandidate,
      redOnCandidateAt: _red.onCandidate,
      whiteDarkMs: _white.darkMs,
      redDarkMs: _red.darkMs,
    );
  }

  /// Живой отсчёт: амплитуда = подъём своей зоны над недавним «полом» (колпака
  /// и, если он слышен, ореола), событие — подтверждённый гистерезисом переход.
  /// Зона меряется яркостью области; кадр, не похожий ни на одну лампу, здесь
  /// тоже не отбрасывается: если своя область поднялась сильнее чужой — это
  /// вспышка СВОЕЙ лампы, а какого она цвета, спрашивать не у кого.
  ///
  /// Наружу отдаётся измеренный подъём ([LampEvaluation.whiteAmplitude]), а
  /// гистерезис работает по подъёму без общего для обеих рамок света
  /// ([LampEvaluation.whiteNet]) — иначе засветка соседней лампы навсегда
  /// держала бы канал в «горит» (см. [LiveReference.step]).
  ///
  /// `change`/`explained`/`residual` в этом режиме не имеют смысла разложения
  /// на эталоны, поэтому `residual` = 0: необъяснённых кадров нет по
  /// определению, а `change` = длина вектора подъёмов — та же величина.
  LampEvaluation _evaluateLive(LampFrame frame) {
    final LiveReading reading = _live.step(frame);

    final bool ambiguous = reading.whiteAboveOn && reading.redAboveOn;
    HitColor? winner;
    if (ambiguous) {
      _ambiguousFrames++;
      winner =
          reading.whiteRise / _positive(reading.whiteLevel) >=
              reading.redRise / _positive(reading.redLevel)
          ? HitColor.white
          : HitColor.red;
    }
    // Та же одна корзина, что и в HSV: проигравший канал не доходит до
    // гистерезиса ([_oneBasket]).
    final bool whiteVeto =
        reading.whiteAboveOn && (!ambiguous || winner == HitColor.white);
    final bool redVeto =
        reading.redAboveOn && (!ambiguous || winner == HitColor.red);

    final ({bool becameOn, bool becameOff}) whiteStep = _white.step(
      aboveOn: whiteVeto,
      belowOff: reading.whiteBelowOff,
      amplitude: reading.whiteNet,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
      offConfirmMs: config.offConfirmMs,
      floorAmplitude: config.referenceMinRise,
      valid: reading.whiteValid,
    );
    final ({bool becameOn, bool becameOff}) redStep = _red.step(
      aboveOn: redVeto,
      belowOff: reading.redBelowOff,
      amplitude: reading.redNet,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
      offConfirmMs: config.offConfirmMs,
      floorAmplitude: config.referenceMinRise,
      valid: reading.redValid,
    );

    final double change = math.sqrt(
      reading.whiteRise * reading.whiteRise + reading.redRise * reading.redRise,
    );

    final ({bool redOff, bool redOn, bool whiteOff, bool whiteOn}) basket =
        _oneBasket(
          whiteOn: whiteStep.becameOn,
          redOn: redStep.becameOn,
          whiteOff: whiteStep.becameOff,
          redOff: redStep.becameOff,
          winner: winner,
          whiteAmp: reading.whiteRise,
          redAmp: reading.redRise,
        );

    return LampEvaluation(
      timestamp: frame.timestamp,
      whiteAmplitude: reading.whiteRise,
      redAmplitude: reading.redRise,
      change: change,
      explained: change,
      residual: 0,
      unexplained: false,
      whiteOn: basket.whiteOn,
      redOn: basket.redOn,
      whiteOff: basket.whiteOff,
      redOff: basket.redOff,
      whiteLit: _white.lit,
      redLit: _red.lit,
      whiteNet: reading.whiteNet,
      redNet: reading.redNet,
      ambiguous: ambiguous,
      ambiguousWinner: winner,
      whiteOnCandidateAt: _white.onCandidate,
      redOnCandidateAt: _red.onCandidate,
      whiteDarkMs: _white.darkMs,
      redDarkMs: _red.darkMs,
    );
  }

  /// HSV-отсчёт: амплитуда = подъём ДОЛИ СВОЕГО ЦВЕТА над «полом» своей зоны,
  /// а «какая это лампа» решает не корзина и не место рамки, а перевес своего
  /// подъёма над чужим ([LampConfig.hsvGate]). Гистерезис тот же самый
  /// ([_LampTracker]), только в долях цветных пикселей.
  ///
  /// Отличий от [_evaluateLive] два, и оба из замеров: здесь нет ореола (модель
  /// проверялась по одной зоне) и нет правила «смена сцены» — его роль играет
  /// стоп на потолке сенсора внутри [HsvReference], потому что белая лампа,
  /// залившая всю сцену, по яркости неотличима от включённого света в зале, а
  /// по цвету — отличима почти всегда.
  LampEvaluation _evaluateHsv(LampFrame frame) {
    final LiveReading reading = _hsv.step(frame);

    final bool ambiguous = reading.whiteAboveOn && reading.redAboveOn;
    HitColor? winner;
    if (ambiguous) {
      _ambiguousFrames++;
      winner =
          reading.whiteRise / _positive(reading.whiteLevel) >=
              reading.redRise / _positive(reading.redLevel)
          ? HitColor.white
          : HitColor.red;
    }

    // При неоднозначности проигравший канал не получает «выше ON»: раньше
    // победитель только писался в диагностику, а оба трекера шли независимо.
    final bool whiteAbove =
        reading.whiteAboveOn && (!ambiguous || winner == HitColor.white);
    final bool redAbove =
        reading.redAboveOn && (!ambiguous || winner == HitColor.red);

    final ({bool becameOn, bool becameOff}) whiteStep = _white.step(
      aboveOn: whiteAbove,
      belowOff: reading.whiteBelowOff,
      amplitude: reading.whiteRise,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
      offConfirmMs: config.offConfirmMs,
      floorAmplitude: config.hsvMinRise,
      valid: reading.whiteValid,
    );
    final ({bool becameOn, bool becameOff}) redStep = _red.step(
      aboveOn: redAbove,
      belowOff: reading.redBelowOff,
      amplitude: reading.redRise,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
      offConfirmMs: config.offConfirmMs,
      floorAmplitude: config.hsvMinRise,
      valid: reading.redValid,
    );

    // Одна вспышка — одна корзина ([_oneBasket]): залипший «горит» проигравшей
    // лампы съел бы её следующую вспышку, а событие, попавшее в обе корзины,
    // удваивает счёт.
    final ({bool redOff, bool redOn, bool whiteOff, bool whiteOn}) basket =
        _oneBasket(
          whiteOn: whiteStep.becameOn,
          redOn: redStep.becameOn,
          whiteOff: whiteStep.becameOff,
          redOff: redStep.becameOff,
          winner: winner,
          whiteAmp: reading.whiteRise,
          redAmp: reading.redRise,
        );
    // Горящему каналу «пол» не двигается — см. [HsvReference.hold].
    _hsv.hold(white: _white.lit, red: _red.lit);

    final double change = math.sqrt(
      reading.whiteRise * reading.whiteRise + reading.redRise * reading.redRise,
    );

    return LampEvaluation(
      timestamp: frame.timestamp,
      whiteAmplitude: reading.whiteRise,
      redAmplitude: reading.redRise,
      change: change,
      explained: change,
      residual: 0,
      unexplained: false,
      whiteOn: basket.whiteOn,
      redOn: basket.redOn,
      whiteOff: basket.whiteOff,
      redOff: basket.redOff,
      whiteLit: _white.lit,
      redLit: _red.lit,
      whiteNet: reading.whiteNet,
      redNet: reading.redNet,
      ambiguous: ambiguous,
      ambiguousWinner: winner,
      whiteOnCandidateAt: _white.onCandidate,
      redOnCandidateAt: _red.onCandidate,
      whiteDarkMs: _white.darkMs,
      redDarkMs: _red.darkMs,
    );
  }

  /// Уровень не бывает нулевым (минимум — [LampConfig.referenceMinRise]), но
  /// делить на него всё равно не хочется: конфиг можно испортить в JSON.
  static double _positive(double value) => value > 0 ? value : 1e-6;
}
