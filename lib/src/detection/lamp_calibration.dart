import 'dart:math' as math;
import 'dart:typed_data';

import '../models/frame_features.dart';
import '../models/lamp_config.dart';
import 'exposure_guard.dart';
import 'response_model.dart';

/// Шаг калибровки — отдельная кнопка на экране.
///
/// Калибровка не одна кнопка и не очередь с таймерами: у каждого состояния своя
/// кнопка, и оператор жмёт её сам, когда видит в кадре нужное — сначала обе
/// лампы выключены, затем горит белая, затем горит красная. Только так детектор
/// получает два эталона и может отличить одну лампу от другой по форме
/// изменения кадра, а не по цвету пикселя.
enum CalibrationStep {
  background('фон', 'Держите обе лампы выключенными', 'bg', 'ФОН'),
  whiteOn('белая горит', 'Зажгите белую лампу и держите', 'white_on', 'БЕЛАЯ'),
  redOn('красная горит', 'Белую погасите, зажгите красную и держите', 'red_on', 'КРАСНАЯ');

  const CalibrationStep(this.label, this.prompt, this.csvTag, this.button);

  /// Следующий по порядку шаг или null, если этот последний. Порядок — только
  /// подсказка: кнопки снимаются в любом, а этот getter знает, куда вести
  /// взгляд, если ничего не переснимается.
  CalibrationStep? get next =>
      index + 1 < values.length ? values[index + 1] : null;

  /// Короткое имя состояния для таблиц и логов.
  final String label;

  /// Что сказать оператору перед набором этого шага. Подсказка обязана быть
  /// законченным действием: что жечь, что гасить и что нажать, когда наберётся
  /// нужное число кадров, — иначе человек стоит у лампы и не знает, готово уже
  /// или нет.
  final String prompt;

  /// Метка шага в колонке `calibration_step` CSV — по ней калибровка
  /// восстанавливается при прогоне записанного файла без телефона.
  final String csvTag;

  /// Надпись на кнопке шага. Одно имя живёт и в экранных текстах ошибок —
  /// «жми «2 БЕЛАЯ»» должно называть ровно ту кнопку, которую человек видит.
  final String button;

  /// Кнопка этого шага, как её печатать в подсказках: «2 БЕЛАЯ».
  String get key => '$number $button';

  /// Шаг по его CSV-метке (null, если метки нет или она не распознана).
  static CalibrationStep? fromCsvTag(String? tag) {
    if (tag == null || tag.isEmpty) {
      return null;
    }
    for (final CalibrationStep step in values) {
      if (step.csvTag == tag) {
        return step;
      }
    }
    return null;
  }

  /// Номер шага с 1 — так его видит человек.
  int get number => index + 1;

  bool get isFinal => index == CalibrationStep.values.length - 1;

  static int get count => values.length;
}

/// Прогресс текущего шага калибровки.
class CalibrationProgress {
  const CalibrationProgress({
    required this.collected,
    required this.needed,
    this.step = CalibrationStep.background,
  });

  final int collected;
  final int needed;
  final CalibrationStep step;

  int get totalSteps => CalibrationStep.count;
  bool get isComplete => collected >= needed;
  int get remaining => (needed - collected).clamp(0, needed);

  @override
  String toString() =>
      'Калибровка ${step.number}/$totalSteps (${step.label}): $collected/$needed';
}

/// Калибровка не удалась (нестабильный фон, лампа не увидена и т. п.).
class CalibrationException implements Exception {
  const CalibrationException(this.message, {this.step, String? brief})
    : brief = brief ?? message;

  final String message;

  /// Шаг, на котором всё сломалось, — чтобы UI сказал, что повторять.
  final CalibrationStep? step;

  /// То же самое для экрана: человек у лампы держит её одной рукой и длинный
  /// текст с формулами у видоискателя не читает, поэтому здесь — короткая
  /// строка «какой шаг и почему».
  final String brief;

  @override
  String toString() => 'Калибровка отвергнута: $message';
}

/// Что показал завершённый шаг калибровки — числа, которые должен увидеть
/// оператор, а не только «готово».
class CalibrationReport {
  const CalibrationReport({
    required this.step,
    required this.frameCount,
    required this.noise,
    this.response,
    this.separationSigmas,
    this.crosstalk,
    this.whiteAmplitudeNoise,
    this.redAmplitudeNoise,
    this.baseline,
  });

  final CalibrationStep step;
  final int frameCount;

  /// σ кадров этого шага в единицах вектора (самая шумная признак-координата).
  final double noise;

  /// ||отклик − фон|| и во сколько раз он больше шума. У шага «фон» отклика нет.
  final double? response;
  final double? separationSigmas;

  /// Насколько две лампы меняют картину одинаково (0..1) и σ амплитуды в долях
  /// отклика. Появляются только на последнем шаге, когда есть оба эталона.
  final double? crosstalk;
  final double? whiteAmplitudeNoise;
  final double? redAmplitudeNoise;

  /// Готовая калибровка — только на последнем шаге.
  final LampBaseline? baseline;

  /// Строка в панель состояния: чем шаг кончился, числом, а не обещанием.
  String describe() {
    final String head = switch (step) {
      CalibrationStep.background =>
        'Фон: $frameCount кадров, шум ${noise.toStringAsFixed(4)}',
      CalibrationStep.whiteOn =>
        'Белая увидена: отклик ${response?.toStringAsFixed(4)} = '
        '${separationSigmas?.toStringAsFixed(1)}σ шума',
      CalibrationStep.redOn =>
        'Красная увидена: отклик ${response?.toStringAsFixed(4)} = '
        '${separationSigmas?.toStringAsFixed(1)}σ шума; перетекание '
        '${((crosstalk ?? 0) * 100).toStringAsFixed(0)}%, шум амплитуды '
        'W ${((whiteAmplitudeNoise ?? 0) * 100).toStringAsFixed(1)}% / '
        'R ${((redAmplitudeNoise ?? 0) * 100).toStringAsFixed(1)}%',
    };
    // Дальше обязана идти одна короткая команда: что жечь и что нажать.
    // Длинный текст оператор у экрана не читает, он держит лампу рукой.
    final String nextStep = switch (step) {
      CalibrationStep.background => '. Дальше: включи белую и жми «${CalibrationStep.whiteOn.key}»',
      CalibrationStep.whiteOn =>
        '. Дальше: гаси белую, включай красную и жми «${CalibrationStep.redOn.key}»',
      CalibrationStep.redOn => '. Готово, можно считать',
    };
    return '$head$nextStep';
  }
}

/// Набор трёх состояний и самопроверка полученной модели отклика.
///
/// Отвечает только за калибровку: собирать кадры, отбраковывать шумный шаг и
/// отвергать калибровку, в которой лампа не увидна. Решает по готовым эталонам
/// `LampResponseModel`, а события — `LampDetector`.
class LampCalibration {
  LampCalibration(this.config);

  /// Пороги можно менять на лету (подбор по записанным CSV).
  LampConfig config;

  final List<LampFrame> _frames = <LampFrame>[];
  final Map<CalibrationStep, CalibrationState> _states =
      <CalibrationStep, CalibrationState>{};

  /// Свет, при котором снят каждый набранный шаг: выдержка и
  /// чувствительность. Три состояния обязаны быть сняты при ОДНОЙ экспозиции:
  /// иначе разность состояний — это не отклик лампы, а разница двух настроек
  /// сенсора, и рабочий прогон начал бы считать такие скачки вспышками. Если
  /// камера метки не отдаёт, записи нет и проверка молчит.
  final Map<CalibrationStep, ({int? ns, double? gain})> _stepExposure =
      <CalibrationStep, ({int? ns, double? gain})>{};

  CalibrationStep _step = CalibrationStep.background;

  /// Шаг, который набирается сейчас.
  CalibrationStep get step => _step;

  /// Каким вектором измерена эта калибровка: восемью яркостными областями.
  /// Обязан совпадать с вектором `LampResponseModel`, иначе отчёт шага и
  /// решение детектора считаются в разных числах.
  LampVector get vector => const LampVector();

  /// Прежний фон — единственное, с чем можно сравнить кадр, пока свой шаг
  /// «фон» ещё не набран. Нужен только подсказке мастера калибровки («лампа
  /// всё ещё горит, погаси»), по ней решение о наборе кадров не принимается:
  /// старый эталон может относиться к другой сцене.
  CalibrationState? backgroundReference;

  /// Состояния, уже набранные с начала текущей калибровки.
  List<CalibrationStep> get completedSteps =>
      CalibrationStep.values.where(_states.containsKey).toList(growable: false);

  bool get isComplete => _states.length == CalibrationStep.count;

  CalibrationProgress get progress => CalibrationProgress(
    collected: _frames.length,
    needed: config.calibrationFrames,
    step: _step,
  );

  /// Пороги, отделяющие подъём лампы от шума: не меньше `lampGateSigmas` σ
  /// фона, но и не меньше `lampGateMinLuma` уровней яркости — иначе на
  /// спокойной сцене лампу «увидит» от одного дрога автоэкспозиции.
  static const double lampGateSigmas = 4;

  /// `lampGateAsymmetry` — во сколько раз своя рамка обязана подняться сильнее
  /// чужой. Именно это и есть ответ на автоэкспозицию: общий подъём света
  /// поднимает обе рамки почти одинаково, лампа шага — только свою.
  static const double lampGateMinLuma = 12.0;
  static const double lampGateAsymmetry = 1.5;

  /// Зажглась ли лампа этого шага прямо сейчас.
  ///
  /// Считается по яркости СВОИХ областей — ядра и кольца этой рамки против тех
  /// же областей фона ([_lit]). По доле «своих» цветных пикселей больше
  /// никогда: пересвеченная красная лампа для сенсора белая, и её шаг при
  /// цветовом признаке просто не набирался.
  ///
  /// `false` до того, как набран шаг «фон»: сравнивать ещё не с чем.
  bool lampAppeared(LampFrame frame, CalibrationStep step) {
    final CalibrationState? bg = _states[CalibrationStep.background];
    if (bg == null || step == CalibrationStep.background) {
      return false;
    }
    return _lit(frame, step, bg);
  }

  /// То же, что [lampAppeared], но пока свой фон не набран — по ПРЕЖНЕМУ фону.
  /// Исключительно для подсказки на шаге 1: без неё мастер калибровки не может
  /// сказать «ты жмёшь „Набирай" при горящей лампе», а именно так раньше и
  /// умирал канал — свет лампы попадал в эталон фона.
  bool lampLikelyLit(LampFrame frame, CalibrationStep step) {
    final CalibrationState? bg =
        _states[CalibrationStep.background] ?? backgroundReference;
    if (bg == null || step == CalibrationStep.background) {
      return false;
    }
    return _lit(frame, step, bg);
  }

  /// Вспышка лампы шага по яркости её собственных областей: ядро и кольцо
  /// этой рамки против тех же областей фона.
  ///
  /// Чужая рамка нужна вторым условием, а не первым: автоэкспозиция и общий
  /// свет поднимают обе рамки почти одинаково, лампа шага — свою заметно
  /// сильнее. Именно эту асимметрию и проверяет `lampGateAsymmetry`; без неё
  /// яркостный порог ловил бы каждый дрог экспозиции как «лампа зажглась».
  bool _lit(LampFrame frame, CalibrationStep step, CalibrationState bg) {
    final bool white = step == CalibrationStep.whiteOn;
    final double own = _rise(
      white ? frame.white : frame.red,
      white ? bg.white : bg.red,
      white ? frame.whiteRing : frame.redRing,
      white ? bg.whiteRing : bg.redRing,
    );
    final double other = _rise(
      white ? frame.red : frame.white,
      white ? bg.red : bg.white,
      white ? frame.redRing : frame.whiteRing,
      white ? bg.redRing : bg.whiteRing,
    );
    // Шум своей области: и ядра, и кольца, если кольцо мерилось.
    final FrameFeatures sigma = white ? bg.whiteSigma : bg.redSigma;
    final FrameFeatures? ringSigma = white ? bg.whiteRingSigma : bg.redRingSigma;
    double gate = math.max(sigma.meanY, sigma.p90Luma);
    if (ringSigma != null) {
      gate = math.max(gate, math.max(ringSigma.meanY, ringSigma.p90Luma));
    }
    return own >= math.max(lampGateMinLuma, lampGateSigmas * gate) &&
        own >= other * lampGateAsymmetry;
  }

  /// Наибольший ПОДЪЁМ яркости среди областей одной рамки (уровни 0..255).
  /// Падение яркости вспышкой не считается, поэтому отрицательные разности
  /// просто не проходят порог.
  static double _rise(
    FrameFeatures current,
    FrameFeatures background,
    FrameFeatures? currentRing,
    FrameFeatures? backgroundRing,
  ) {
    double best = math.max(
      current.meanY - background.meanY,
      current.p90Luma - background.p90Luma,
    );
    if (currentRing != null && backgroundRing != null) {
      best = math.max(
        best,
        math.max(
          currentRing.meanY - backgroundRing.meanY,
          currentRing.p90Luma - backgroundRing.p90Luma,
        ),
      );
    }
    return best;
  }

  /// Начать заново с фона, забыв всё, что было набрано.
  void reset() {
    _frames.clear();
    _states.clear();
    _stepExposure.clear();
    _step = CalibrationStep.background;
    // Прежний фон — только подставка под подсказку, пока своего шага «фон» нет;
    // при следующем запуске калибровки сессия подставит его заново.
    backgroundReference = null;
  }

  /// Забыть недобранные кадры текущего шага, сохранив уже принятые состояния.
  /// Нужен, когда шаг пришлось переснимать прямо во время набора: например,
  /// сменилась экспозиция из-за пересвета, и первые кадры шага относятся уже к
  /// другому свету.
  void discardCurrentStep() => _frames.clear();

  /// Встать на шаг `target`, как будто до него всё уже снято: его собственные
  /// принятые состояния и все состояния, снятые ПОСЛЕ него, стираются, потому
  /// что пересъёмка делает их недействительными. Раньше набор шёл строго по
  /// порядку и за один подход, поэтому переснять одну красную лампу было
  /// нельзя — приходилось гонять оператора по всем трём шагам.
  void goToStep(CalibrationStep target) {
    _frames.clear();
    for (final CalibrationStep step in CalibrationStep.values) {
      if (step.index >= target.index) {
        _states.remove(step);
        _stepExposure.remove(step);
      }
    }
    _step = target;
  }

  /// Подставить ранее измеренные состояния, чтобы снять по кнопке ровно один
  /// шаг, а не всю калибровку: передвинули рамку красной — переснимаем красную,
  /// фон и белая остаются прежними. Заполняются только пустые ячейки, поэтому
  /// вызов ничего не портит, если состояние уже набрано в этом прогоне.
  void adoptStates(LampBaseline baseline) {
    _states[CalibrationStep.background] ??= baseline.background;
    _states[CalibrationStep.whiteOn] ??= baseline.whiteOn;
    _states[CalibrationStep.redOn] ??= baseline.redOn;
    // Подставленные состояния сняты при экспозиции из baseline: сверка
    // начинается с неё, иначе переснятый шаг сошёлся бы с прежним молча, хотя
    // свет между ними уже разный.
    final ({int? ns, double? gain}) adopted =
        (ns: baseline.exposureTimeNs, gain: baseline.sensorSensitivity);
    for (final CalibrationStep step in CalibrationStep.values) {
      _stepExposure[step] ??= adopted;
    }
    // Прежний фон годится и как опора для подсказки «лампа ещё горит».
    backgroundReference ??= baseline.background;
  }

  /// Световые условия одного шага калибровки: все его кадры обязаны быть сняты
  /// при одной экспозиции, и эта экспозиция обязана совпадать с экспозицией
  /// двух других шагов.
  ///
  /// Правило не «улучшает точность», оно отменяет измерение: разность состояний
  /// и есть отклик лампы, а при разном свете в разности сидит ещё и разница
  /// настроек сенсора. Камера, которая метки не отдаёт, проходит молча:
  /// сравнивать нечего, а выдумывать условие нельзя.
  void _checkExposure(List<LampFrame> frames) {
    int? ns;
    double? gain;
    for (final LampFrame frame in frames) {
      if (!ExposureGuard.same(ns, frame.exposureTimeNs, gain, frame.sensorSensitivity)) {
        throw CalibrationException(
          'Экспозиция менялась прямо во время набора «${_step.label}»: '
          '${ExposureGuard.describe(aNs: ns, aGain: gain, bNs: frame.exposureTimeNs, bGain: frame.sensorSensitivity)}. '
          'Свет должен быть заперт до старта шага — пересними шаг, когда камера '
          'успокоится.',
          step: _step,
          brief: 'Свет плыл во время «${_step.label}»: жди секунду после «Пуск» шага',
        );
      }
      ns ??= frame.exposureTimeNs;
      gain ??= frame.sensorSensitivity;
    }
    for (final MapEntry<CalibrationStep, ({int? ns, double? gain})> entry
        in _stepExposure.entries) {
      if (entry.key == _step) {
        continue;
      }
      if (!ExposureGuard.same(
        entry.value.ns,
        ns,
        entry.value.gain,
        gain,
      )) {
        throw CalibrationException(
          '«${entry.key.label}» снят при другом свете, чем «${_step.label}»: '
          '${ExposureGuard.describe(aNs: entry.value.ns, aGain: entry.value.gain, bNs: ns, bGain: gain)}. '
          'Все три состояния обязаны быть набраны на одной запертой экспозиции — '
          'пересними «${entry.key.label}» тоже.',
          step: _step,
          brief: 'Разный свет: пересними «${entry.key.key}» на той же экспозиции',
        );
      }
    }
    _stepExposure[_step] = (ns: ns, gain: gain);
  }

  /// Кадр текущего шага. Возвращает отчёт, когда шаг завершён, и null, пока
  /// кадров ещё не хватает.
  ///
  /// Бросает [CalibrationException], если шаг шумел или калибровка в целом не
  /// увидела лампу; тогда набор этого шага обнуляется, а уже принятые состояния
  /// сохраняются — повторять нужно только провалившийся шаг.
  CalibrationReport? addFrame(LampFrame frame) {
    _frames.add(frame);
    if (_frames.length < config.calibrationFrames) {
      return null;
    }
    final List<LampFrame> frames = List<LampFrame>.of(_frames);
    _frames.clear();
    // Фон берётся ДО записи нового состояния: кнопки снимают шаги в любом
    // порядке, и «своего» фона может не оказаться вовсе (его ещё не жали).
    final CalibrationState? bg = _states[CalibrationStep.background];
    // Свет проверяется до принятия состояния: отвергнутый шаг не должен
    // оставлять в наборе эталон, снятый при другой экспозиции.
    _checkExposure(frames);
    final CalibrationState state = stateFrom(
      frames,
      config,
      step: _step,
      // На шагах горящей лампы шум меряется относительно фона: мигающая лампа —
      // это сигнал, а не помеха, и абсолютный порог фона отвергал такой шаг.
      reference: _step == CalibrationStep.background ? null : bg,
    );
    _states[_step] = state;

    // Отклик есть только против чего сравнивать: снятый без фона шаг ещё ни о
    // чём не говорит, поэтому числа в отчёте просто отсутствуют.
    final bool againstBackground = _step != CalibrationStep.background;
    final CalibrationReport report = CalibrationReport(
      step: _step,
      frameCount: state.frameCount,
      noise: vector.norm(vector.ofSigma(state)),
      response: againstBackground && bg != null
          ? vector.norm(vector.ofResponse(state, bg))
          : null,
      separationSigmas:
          againstBackground && bg != null ? _separationAgainstBackground(state, bg) : null,
    );

    // Модель сборная: её можно отвергнуть только когда есть все три состояния,
    // в каком бы порядке они ни были сняты. Прежний «проверять лишь на
    // последнем шаге» правил порядок и не давал переснять один шаг по кнопке:
    // снятая красная висела бы непринятой, пока оператор не пройдёт снова всё.
    if (_states.length < CalibrationStep.count) {
      if (!_step.isFinal) {
        _step = CalibrationStep.values[_step.index + 1];
      }
      return report;
    }
    return _validate(report);
  }

  /// Собирает baseline, проверяет эталоны и дописывает числа проверки в отчёт.
  CalibrationReport _validate(CalibrationReport report) {
    // В baseline кладётся экспозиция, уже сверенная `_checkExposure`: все три
    // шага обязаны сойтись на ней, поэтому неважно, чья именно запись. Нужна
    // она не калибровке, а рабочему прогону: по ней сессия поймёт, что свет
    // сменился и эталон больше не описывает кадр.
    final ({int? ns, double? gain}) shot = _stepExposure[CalibrationStep.background] ??
        (_stepExposure.isEmpty
            ? (ns: null, gain: null)
            : _stepExposure.values.first);
    final LampBaseline baseline = LampBaseline(
      background: _states[CalibrationStep.background]!,
      whiteOn: _states[CalibrationStep.whiteOn]!,
      redOn: _states[CalibrationStep.redOn]!,
      capturedAtMs: DateTime.now().millisecondsSinceEpoch,
      exposureTimeNs: shot.ns,
      sensorSensitivity: shot.gain,
    );
    final LampResponseModel model = LampResponseModel(baseline);
    if (baseline.background.whiteRing == null) {
      // Вектор без колец — это те же два колпака и ничего больше: отличить
      // засветку от своей лампы становится нечем, и модель начала бы решать по
      // обрезанному вектору, не сказав об этом.
      throw CalibrationException(
        'Калибровка не измеряла ореолы: кольцо вокруг рамок выключено '
        '(ringScale = 1). Включи измерение кольца и повтори все три шага — без '
        'ореолов восьмимерный вектор вырождается в яркость двух колпаков.',
        brief: 'Нет колец: включи ringScale > 1 и повтори шаги 1–3.',
      );
    }
    final String? reason = model.invalidReason(config.templateMinSeparation);
    if (reason != null) {
      // Виноват тот шаг, эталон которого и не годится: переснимать всегда
      // последний («красная») — значит гонять оператора по кругу, когда
      // отклика не дала белая лампа.
      final CalibrationStep step = model.failingStep(config.templateMinSeparation);
      _states.remove(step);
      _step = step;
      throw CalibrationException(
        reason,
        step: step,
        brief: '«${step.key}»: ${_clip(reason)}. Пересними этот шаг',
      );
    }
    // Успех: состояния превратились в baseline, детектору больше нечего
    // набирать. Забываем их, чтобы следующее нажатие «Калибровка» честно
    // начиналось с шага 1, а не дописывало третий шаг поверх готовой модели.
    reset();
    return CalibrationReport(
      step: report.step,
      frameCount: report.frameCount,
      noise: report.noise,
      response: report.response,
      separationSigmas: report.separationSigmas,
      crosstalk: model.crosstalk,
      whiteAmplitudeNoise: model.whiteAmplitudeNoise,
      redAmplitudeNoise: model.redAmplitudeNoise,
      baseline: baseline,
    );
  }

  double _separationAgainstBackground(CalibrationState state, CalibrationState bg) {
    final LampVector v = vector;
    final double response = v.norm(v.ofResponse(state, bg));
    final Float64List a = v.ofSigma(state);
    final Float64List b = v.ofSigma(bg);
    double sum = 0;
    for (int i = 0; i < v.length; i++) {
      final double s = math.sqrt(a[i] * a[i] + b[i] * b[i]);
      sum += s * s;
    }
    final double sigma = math.sqrt(sum);
    return sigma == 0 ? double.infinity : response / sigma;
  }

  /// Среднее и σ признаков обеих рамок по кадрам одного шага. Используется и
  /// живой калибровкой, и прогоном CSV.
  ///
  /// [reference] — набранный фон этого же прогона. Если он передан (шаги
  /// горящей лампы), допуск шума растёт пропорционально отклику признака:
  /// мигание самой лампы — это сигнал, а не помеха, и абсолютный порог фона
  /// отвергал ровно те кадры, ради которых шаг собирался.
  static CalibrationState stateFrom(
    List<LampFrame> frames,
    LampConfig config, {
    CalibrationStep step = CalibrationStep.background,
    CalibrationState? reference,
  }) {
    if (frames.isEmpty) {
      throw const CalibrationException('нет кадров для калибровки');
    }
    final FrameFeatures whiteMean = _mean(frames.map((LampFrame f) => f.white));
    final FrameFeatures redMean = _mean(frames.map((LampFrame f) => f.red));
    final FrameFeatures whiteSigma = _std(frames.map((LampFrame f) => f.white));
    final FrameFeatures redSigma = _std(frames.map((LampFrame f) => f.red));
    // Кольца набираются только если их измеряли. Отсутствие кольца в состоянии
    // обязано остаться null: подставить туда ноль означало бы «эта область
    // всегда была чёрной», и модель начала бы решать по выдуманному ореолу.
    final List<FrameFeatures>? whiteRing = _ringFrames(frames, (LampFrame f) => f.whiteRing);
    final List<FrameFeatures>? redRing = _ringFrames(frames, (LampFrame f) => f.redRing);
    final CalibrationState state = CalibrationState(
      white: whiteMean,
      red: redMean,
      whiteSigma: whiteSigma,
      redSigma: redSigma,
      whiteRing: whiteRing == null ? null : _mean(whiteRing),
      redRing: redRing == null ? null : _mean(redRing),
      whiteRingSigma: whiteRing == null ? null : _std(whiteRing),
      redRingSigma: redRing == null ? null : _std(redRing),
      frameCount: frames.length,
    );
    // Шум проверяется по всем признакам вектора, а не по двум «рабочим»:
    // дёргается яркость — дёргается и решение, хоть доли и стоят на месте.
    // В состояние ложится обычная σ (пороги от неё остаются консервативными),
    // а шаг отбраковывается по устойчивой к выбросам: один кадр с прошедшей
    // рукой не должен обесценивать весь набор.
    final LampVector vector = const LampVector();
    final Float64List mean = vector.ofState(state);
    final Float64List sigma = _robustSigma(frames, vector);
    final Float64List? from =
        reference == null ? null : vector.ofState(reference);
    double worstRatio = 0;
    int worstIndex = -1;
    double worstAllowed = 0;
    for (int i = 0; i < sigma.length; i++) {
      final double shift = from == null ? 0 : (mean[i] - from[i]).abs();
      final double allowed = math.max(
        config.calibrationMaxNoise,
        config.calibrationNoiseRatio * shift,
      );
      // Деление на ноль здесь закрыто: допуск может быть выставлен в 0
      // («шума нет вообще»), а σ синтетики равна нулю — 0/0 дало бы NaN, и
      // проверка молча перестала бы что-либо проверять.
      final double ratio = sigma[i] / math.max(allowed, 1e-9);
      if (ratio > worstRatio) {
        worstRatio = ratio;
        worstIndex = i;
        worstAllowed = allowed;
      }
    }
    if (worstRatio > 1) {
      final String detail =
          'σ ${vector.name(worstIndex)} = ${sigma[worstIndex].toStringAsFixed(4)}, '
          'допустимо ≤ ${worstAllowed.toStringAsFixed(4)}';
      final String hold = step == CalibrationStep.background
          ? 'Держи лампы погашенными'
          : 'Держи лампу горящей, не загораживая рамку';
      throw CalibrationException(
        '${step.label}: шаг шумит ($detail): лампа мигала, камера двигалась '
        'или менялся свет. Повтори шаг ${step.number}.',
        step: step,
        brief: '«${step.key}»: $detail. $hold и жми эту кнопку снова.',
      );
    }
    return state;
  }

  /// Устойчивая к выбросам σ каждого признака вектора: 1.4826 × медиана
  /// отклонений от медианы. Обычная σ на 30 кадрах тонет от одного выброса
  /// (прошла рука, мигнул свет), а такое отклонение — это ровно то, что шаг
  /// обязан пережить: решение по медиане остаётся на выбросы нечувствительным.
  static Float64List _robustSigma(List<LampFrame> frames, LampVector vector) {
    final Float64List out = Float64List(vector.length);
    final List<Float64List> rows = frames
        .map((LampFrame f) => vector.of(f))
        .toList(growable: false);
    final List<double> values = <double>[];
    for (int i = 0; i < vector.length; i++) {
      values
        ..clear()
        ..addAll(rows.map((Float64List v) => v[i]));
      out[i] = 1.4826 * _medianDeviation(values);
    }
    return out;
  }

  /// Медиана абсолютных отклонений от медианы (вход не меняется).
  static double _medianDeviation(List<double> values) {
    if (values.length < 2) {
      return 0;
    }
    final List<double> sorted = List<double>.of(values)..sort();
    final double med = _medianOf(sorted);
    final List<double> deviations =
        values.map((double v) => (v - med).abs()).toList(growable: false)..sort();
    return _medianOf(deviations);
  }

  /// Медиана отсортированного списка.
  static double _medianOf(List<double> sorted) {
    final int n = sorted.length;
    if (n == 0) {
      return 0;
    }
    return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  }

  /// Короткая версия длинного текста ошибки: у экрана читают одну строку.
  static String _clip(String s) => s.length <= 90 ? s : '${s.substring(0, 90)}…';

  /// Кадры шага, в которых кольцо этой рамки реально измерялось. Null, если ни
  /// в одном кадре его не было: состояние обязано сказать «область не
  /// измерялась», а не «область всегда была тёмной».
  static List<FrameFeatures>? _ringFrames(
    List<LampFrame> frames,
    FrameFeatures? Function(LampFrame) pick,
  ) {
    final List<FrameFeatures> out = <FrameFeatures>[];
    for (final LampFrame f in frames) {
      final FrameFeatures? ring = pick(f);
      if (ring != null) {
        out.add(ring);
      }
    }
    return out.isEmpty ? null : out;
  }

  /// Среднее всех признаков области. Яркостные признаки усредняются наравне с
  /// цветовыми: решение по вектору обязано знать шум каждой координаты, а доли
  /// цвета остаются в состоянии только для сравнения старого и нового способа.
  static FrameFeatures _mean(Iterable<FrameFeatures> features) {
    double meanY = 0;
    double whiteFrac = 0;
    double redFrac = 0;
    double coolFrac = 0;
    double warmFrac = 0;
    double p90 = 0;
    double stdDev = 0;
    double clipped = 0;
    double samples = 0;
    for (final FrameFeatures f in features) {
      meanY += f.meanY;
      whiteFrac += f.whiteFrac;
      redFrac += f.redFrac;
      coolFrac += f.coolFrac;
      warmFrac += f.warmFrac;
      p90 += f.p90Luma;
      stdDev += f.lumaStdDev;
      clipped += f.clippedRatio;
      samples += f.sampleCount;
    }
    final int n = features.length;
    return FrameFeatures(
      meanY: meanY / n,
      sampleCount: (samples / n).round(),
      whiteFrac: whiteFrac / n,
      redFrac: redFrac / n,
      coolFrac: coolFrac / n,
      warmFrac: warmFrac / n,
      p90Luma: p90 / n,
      lumaStdDev: stdDev / n,
      clippedRatio: clipped / n,
    );
  }

  /// σ всех признаков области — те же координаты, что и у среднего.
  static FrameFeatures _std(Iterable<FrameFeatures> features) => FrameFeatures(
    meanY: _stdOf(features.map((FrameFeatures f) => f.meanY)),
    sampleCount: 0,
    whiteFrac: _stdOf(features.map((FrameFeatures f) => f.whiteFrac)),
    redFrac: _stdOf(features.map((FrameFeatures f) => f.redFrac)),
    coolFrac: _stdOf(features.map((FrameFeatures f) => f.coolFrac)),
    warmFrac: _stdOf(features.map((FrameFeatures f) => f.warmFrac)),
    p90Luma: _stdOf(features.map((FrameFeatures f) => f.p90Luma)),
    lumaStdDev: _stdOf(features.map((FrameFeatures f) => f.lumaStdDev)),
    clippedRatio: _stdOf(features.map((FrameFeatures f) => f.clippedRatio)),
  );

  static double _stdOf(Iterable<double> values) {
    final List<double> list = values.toList();
    if (list.length < 2) {
      return 0;
    }
    final double mean = list.reduce((double a, double b) => a + b) / list.length;
    double sq = 0;
    for (final double v in list) {
      sq += (v - mean) * (v - mean);
    }
    return math.sqrt(sq / (list.length - 1));
  }
}
