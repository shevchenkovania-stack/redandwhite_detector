import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../camera/frame_source.dart';
import '../delivery/hit_event_sender.dart';
import '../detection/exposure_guard.dart';
import '../detection/feature_extractor.dart';
import '../detection/hit_state_machine.dart';
import '../detection/lamp_calibration.dart';
import '../detection/lamp_detector.dart';
import '../detection/response_model.dart';
import '../diagnostics/diagnostics_collector.dart';
import '../diagnostics/feature_csv_recorder.dart';
import '../diagnostics/run_analyzer.dart';
import '../models/frame_features.dart';
import '../models/hit_event.dart';
import '../models/lamp_config.dart';
import '../models/roi.dart';
import '../storage/event_repository.dart';
import 'settings_store.dart';

/// Что именно получает теневой измеритель.
///
/// Смысл класса в одном: второй способ обязан мерить **тот же кадр, что и
/// основной конвейер**, а не пересказывать его результат. Поэтому сюда
/// кладётся и сырая картинка с камеры ([raw]), и геометрия зон ([roi],
/// [mapping]), чем основной конвейер их превращает в пиксели, и уже готовые
/// признаки ([frame]) с решением ([evaluation]) — чтобы было с чем сравнивать.
/// Без сырых пикселей «второй измеритель» не мог бы измерить ничего: [frame]
/// — это числа, которые посчитал рабочий экстрактор.
class ShadowInput {
  const ShadowInput({
    required this.raw,
    required this.roi,
    required this.mapping,
    required this.frame,
    this.evaluation,
  });

  /// Сырой кадр с источника: плоскость Y (YUV420) или упакованные BGRA.
  final RawLampFrame raw;

  /// Зоны ламп в координатах превью — те же, чем решал основной конвейер.
  final RoiLayout roi;

  /// Перенос этих же зон в координаты кадра.
  final FrameMapping mapping;

  /// Признаки этого кадра, посчитанные рабочим [FeatureExtractor].
  final LampFrame frame;

  /// Решение по этому кадру; нет — если кадр был калибровочным или сброшен.
  final LampEvaluation? evaluation;
}

/// Теневой измеритель света: получает тот же кадр и то же решение, что основной
/// конвейер, и обязан остаться наблюдателем.
///
/// Так второй способ измерения сравнивается с рабочим на
/// живых кадрах, не имея шанса повлиять на автомат: результат — `void`, вызов
/// идёт после того, как события уже приняты, а его собственная ошибка
/// ловится. Ничего из принесённого тенем детектор не читает.
typedef ShadowProbe = void Function(ShadowInput input);

/// Всё, что нужно UI про состояние сессии.
class LampStatus {
  const LampStatus({
    required this.running,
    required this.calibrating,
    required this.calibration,
    required this.isCalibrated,
    required this.whiteLit,
    required this.redLit,
    required this.whiteHits,
    required this.redHits,
    required this.sessionId,
    required this.recordingCsv,
    required this.state,
    this.csvPath,
    this.stepResult = '',
    this.completedSteps = const <CalibrationStep>[],
    this.phaseSeconds = 0,
    this.calibrationHint = '',
    this.calibrationError = '',
    this.settling = false,
    this.exposureLocked = true,
    this.overexposed = false,
  });

  static const LampStatus initial = LampStatus(
    running: false,
    calibrating: false,
    calibration: CalibrationProgress(
      collected: 0,
      needed: LampConfig.defaultCalibrationFrames,
    ),
    isCalibrated: false,
    whiteLit: false,
    redLit: false,
    whiteHits: 0,
    redHits: 0,
    sessionId: '',
    recordingCsv: false,
    state: LampSessionState.idle,
  );

  final bool running;
  final bool calibrating;

  /// Прогресс текущего шага, включая [CalibrationProgress.step] с подсказкой
  /// оператору.
  final CalibrationProgress calibration;
  final bool isCalibrated;
  final bool whiteLit;
  final bool redLit;
  final int whiteHits;
  final int redHits;
  final String sessionId;
  final bool recordingCsv;
  final LampSessionState state;
  final String? csvPath;

  /// Чем кончился только что завершённый шаг калибровки — измеренные числа
  /// (отклик, шум, перетекание), а не слово «готово». Пусто, пока шаг набирается.
  final String stepResult;

  /// Какие шаги уже набраны в текущей калибровке (для «шаг 2 из 3»).
  final List<CalibrationStep> completedSteps;

  /// Сколько секунд оператор уже набирает текущий шаг. Это счётчик вверх, а не
  /// обратный отсчёт: включить лампу человек быстрее не успеет от того, что
  /// таймер тикает к нулю, а вот понять, что набор завис, по нему можно.
  final int phaseSeconds;

  /// Одна короткая строка «что делать» для экрана калибровки. Рождается здесь,
  /// а не в UI, потому что зависит от того, увидна ли лампа детектором.
  final String calibrationHint;

  /// Чем закончился только что отвергнутый шаг калибровки — одна короткая
  /// строка прямо над подсказкой. Прежний вариант упал в серую строчку внизу
  /// экрана, оператор её не видел и жал «Калибровка» заново, теряя два
  /// набранных шага. Пусто, пока отказы не случались.
  final String calibrationError;

  /// Идёт набор шага, но первые кадры ещё выбрасываются (стабилизация лампы и
  /// автоэкспозиции). Экран обязан показать это, а не «застывший» счётчик.
  final bool settling;

  /// Заперта ли экспозиция камерой. `false` — автоэкспозиция до сих пор
  /// пересчитывает кадр, и любой её шаг детектор примет за вспышку лампы.
  final bool exposureLocked;

  /// Последняя рамка стоит на клиппинге (Y ≥ [DetectionSession.clipLuma]):
  /// цвета и яркости в таких пикселях нет, канал слепой.
  final bool overexposed;

  String get whiteStatus => whiteLit ? 'ON' : 'OFF';
  String get redStatus => redLit ? 'ON' : 'OFF';
}

/// Склеивает источник кадров, извлечение признаков, детектор, автомат,
/// хранилище, доставку и диагностику. Единственная точка входа для приложения.
class DetectionSession extends ChangeNotifier {
  DetectionSession({
    required this.source,
    required this.repository,
    required this.sender,
    required this.settings,
    required this.csvRecorder,
    LampConfig config = const LampConfig(),
    RoiLayout roi = RoiLayout.defaults,
    DiagnosticsCollector? diagnostics,
    String? sessionId,
  }) : _extractor = FeatureExtractor(config),
       _detector = LampDetector(config),
       _machine = HitStateMachine(sessionId: sessionId ?? const Uuid().v4()),
       diagnostics = diagnostics ?? DiagnosticsCollector(),
       _config = config,
       _roi = roi {
    _dartExtractor = _extractor;
    this.diagnostics.isolateThresholdMs = config.analysisIsolateThresholdMs;
  }

  /// Сколько сообщений об ошибках держать для панели.
  static const int maxStoredErrors = 50;

  /// Сколько кадров текущего шага выбрасывается перед набором. Лампа и
  /// автоэкспозиция камеры приходят в равновесие не в момент нажатия,
  /// переходные кадры исказили бы эталон и шум шага.
  static const int calibrationSettleFrames = 10;

  /// Сколько времени после старта шага кадры считаются переходными. Нужен
  /// вместе с [calibrationSettleFrames]: запись кадра идёт 24–100 мс, и одних
  /// только «10 кадров» хватило бы на четверть секунды, тогда как
  /// перелоксировка экспозиции камеры (её пауза на сходимость + кадры
  /// стабилизации) длится дольше. Шаг набирается, только когда прошли ОБА
  /// условия.
  static const Duration calibrationSettleTime = Duration(milliseconds: 1200);

  /// Яркость, с которой рамка считается стоящей на клиппинге (0..255). Среднее
  /// по рамке выше этого значения означает, что почти все её пиксели упёрлись
  /// в потолок: ни цвета, ни запаса яркости там уже нет.
  static const double clipLuma = 248;

  /// Сколько раз за шаг «фон» разрешено убавить экспозицию из-за пересвета.
  /// Больше одного шага вниз оператор уже не поймёт, что происходит, а на
  /// последующих шагах экспозицию менять поздно — фон набран при другой.
  static const int maxClipCorrections = 2;

  final FrameSource source;
  final EventRepository repository;
  final HitEventSender sender;
  final SettingsStore settings;
  final FeatureCsvRecorder csvRecorder;
  final DiagnosticsCollector diagnostics;

  /// Измеритель признаков текущего кадра. Не final: ветка сравнения датчиков
  /// подменяет его на лету (см. [sensorExtractor]). Штатный Dart-измеритель
  /// хранится отдельно, чтобы возврат к нему не зависел от порядка правок.
  FeatureExtractor _extractor;

  /// Тот измеритель, с которым сессия родилась, — единственный, кого возвращает
  /// `sensorExtractor = null`.
  late final FeatureExtractor _dartExtractor;

  final LampDetector _detector;
  final HitStateMachine _machine;

  LampConfig _config;
  RoiLayout _roi;

  final StreamController<HitEvent> _hits =
      StreamController<HitEvent>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();
  final List<String> _lastErrors = <String>[];

  StreamSubscription<RawLampFrame>? _framesSub;
  StreamSubscription<FrameSourceStatus>? _statusSub;
  Completer<CalibrationReport>? _calibrationCompleter;

  /// Начало набора текущего шага: по нему считается и конец стабилизации, и
  /// счётчик секунд на экране.
  DateTime? _phaseStartedAt;
  int _settleLeft = 0;
  bool _overexposed = false;
  int _clipCorrectionsLeft = maxClipCorrections;
  bool _clipWarned = false;

  /// Свет, при котором набраны текущие измерения: по его смене сессия
  /// сбрасывает калибровку (см. [_onExposureBasisLost]).
  final ExposureGuard _exposure = ExposureGuard();

  /// Теневой измеритель (см. [ShadowProbe]): второй способ мерить свет на тех
  /// же живых кадрах. Null = тени нет, и прогон идёт ровно тем же кодом, что и
  /// без этой возможности.
  ShadowProbe? get shadowProbe => _shadowProbe;

  set shadowProbe(ShadowProbe? value) {
    // Новой тени — новая жалоба: иначе второй подключённый измеритель молчал
    // бы, уже будучи отключённым первым.
    if (!identical(value, _shadowProbe)) {
      _shadowWarned = false;
    }
    _shadowProbe = value;
  }

  ShadowProbe? _shadowProbe;

  /// Нужен, чтобы падающий теневой измеритель не засыпал приложение ошибками
  /// на каждый кадр: показывается только первая.
  bool _shadowWarned = false;

  Future<void>? _delivery;

  bool _busy = false;
  bool _running = false;
  bool _calibrating = false;
  bool _recordingCsv = false;
  bool _csvEnabled = false;
  bool _whiteLit = false;
  bool _redLit = false;
  bool _disposed = false;
  int _whiteHits = 0;
  int _redHits = 0;
  String _lastSignature = '';
  String _stepResult = '';
  String _stepError = '';
  RawLampFrame? _lastFrame;
  LampFrame? _lastLampFrame;
  LampEvaluation? _lastEvaluation;

  /// События, созданные детектором. Подписываться до [start].
  /// Увеличивается после каждого обработанного кадра. `notifyListeners` сессии
  /// фильтруется по сигнатуре (чтобы не перерисовывать весь экран 30 раз/с),
  /// поэтому живые экраны (расшифровка чисел) слушают этот счётчик.
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  Stream<HitEvent> get hits => _hits.stream;

  /// Ошибки камеры и обработки: приложение не падает, всё сюда.
  Stream<String> get errors => _errors.stream;

  List<String> get lastErrors => List<String>.unmodifiable(_lastErrors);

  RoiLayout get roi => _roi;
  LampConfig get config => _config;
  bool get isRunning => _running;
  bool get isCalibrated => _detector.isCalibrated;

  /// Считаются ли события: в режиме живого отсчёта калибровка не обязательна.
  bool get canEvaluate => _detector.canEvaluate;
  String get sessionId => _machine.sessionId;
  int get whiteHits => _whiteHits;
  int get redHits => _redHits;
  LampBaseline? get baseline => _detector.baseline;

  /// Признаки последнего обработанного кадра по обеим рамкам — для «Расшифровки».
  LampFrame? get lastFeatures => _lastLampFrame;

  /// Измеренная модель отклика (эталоны, шумы, перетекание). Null до калибровки.
  LampResponseModel? get model => _detector.model;

  /// Шаг пошаговой калибровки, который набирается сейчас.
  CalibrationStep get calibrationStep => _detector.calibrationStep;

  /// Короткая причина последнего отвергнутого шага (пусто, если отказов не
  /// было). Мастер калибровки показывает её на экране — в лог она тоже идёт,
  /// но у лампы лог никто не читает.
  String get calibrationError => _stepError;

  /// Сколько секунд оператор набирает текущий шаг. Обратно отсчёт не идёт
  /// намеренно: дедлайн на включение лампы не работал — он только выглядел как
  /// время, а набор по его истечении всё равно начинался по не включённой
  /// лампе.
  int get phaseSeconds {
    final DateTime? started = _phaseStartedAt;
    if (started == null || !_calibrating) {
      return 0;
    }
    return DateTime.now().difference(started).inSeconds;
  }

  /// Набор текущего шага ещё только стабилизируется (см.
  /// [calibrationSettleFrames] и [calibrationSettleTime]).
  bool get settling => _calibrating && !_settleFinished;

  bool get _settleFinished {
    final DateTime? started = _phaseStartedAt;
    if (started == null) {
      return _settleLeft <= 0;
    }
    return _settleLeft <= 0 &&
        DateTime.now().difference(started) >= calibrationSettleTime;
  }

  /// Источник, умеющий управлять экспозицией, или null, если не умеет (файл,
  /// тест, симулятор).
  ExposureControl? get _light {
    final FrameSource target = source;
    // Явный `as`: для `abstract interface class` анализатор сужение типа не
    // делает (так же, как с FrameMappingControl в setFrameMapping).
    return target is ExposureControl ? target as ExposureControl : null;
  }

  /// Заперта ли экспозиция. Источник, который управлять ею не умеет, считается
  /// запертым: у него свет не плывёт.
  bool get exposureLocked {
    final ExposureControl? light = _light;
    return light == null || light.exposureLocked;
  }

  /// Одна строка «что делать» для мастера калибровки. Пока шаг набирается —
  /// что должно быть в кадре; пока стоит — какую из трёх кнопок нажать следующей.
  /// Рождается здесь, а не в UI, потому что зависит от того, увидна ли лампа
  /// детектором.
  String get calibrationHint {
    final CalibrationStep step = _detector.calibrationStep;
    if (_calibrating) {
      return switch (step) {
        CalibrationStep.background => 'Держи обе лампы погашенными',
        CalibrationStep.whiteOn => 'Держи белую горящей',
        CalibrationStep.redOn => 'Держи красную горящей',
      };
    }
    if (_isFullyShot) {
      return 'Калибровка есть. Переснять шаг — жми его кнопку';
    }
    return switch (step) {
      CalibrationStep.background =>
        _referenceLit
            ? 'В кадре светло — гаси лампы и жми «1 ФОН»'
            : 'Погаси обе лампы и жми «1 ФОН»',
      CalibrationStep.whiteOn => 'Включи белую и жми «2 БЕЛАЯ»',
      CalibrationStep.redOn =>
        _whiteStillLit
            ? 'Гаси белую — потом жми «3 КРАСНАЯ»'
            : 'Гаси белую, включай красную и жми «3 КРАСНАЯ»',
    };
  }

  /// Все три состояния набраны и модель принята. Отдельное поле для этого не
  /// хранится: после `_validate()` состояния сознательно стёрты, а рабочая
  /// модель осталась — значит «готово» выглядит как рабочий baseline без
  /// недобранных шагов.
  bool get _isFullyShot =>
      _detector.isCalibrated && _detector.completedCalibrationSteps.isEmpty;

  /// Белая всё ещё горит (красную нельзя набирать, пока в кадре белая).
  bool get _whiteStillLit {
    final LampFrame? current = _lastLampFrame;
    if (current == null) {
      return false;
    }
    return _detector.lampAppeared(current, CalibrationStep.whiteOn);
  }

  /// Горит ли хоть одна лампа по ПРЕЖНЕЙ калибровке — подсказка кнопки «1 ФОН»,
  /// у которой своего фона ещё нет. На набор она не влияет: старый эталон может
  /// относиться к другой сцене, поэтому решение всегда за оператором. Именно
  /// этот промах и убивал канал молча: фон набирался при горящей лампе.
  bool get _referenceLit {
    final LampFrame? current = _lastLampFrame;
    if (current == null) {
      return false;
    }
    return _detector.lampLikelyLit(current, CalibrationStep.whiteOn) ||
        _detector.lampLikelyLit(current, CalibrationStep.redOn);
  }

  /// Самая светлая рамка кадра — то, чем объясняется пересвет.
  static double _clipY(LampFrame frame) =>
      frame.white.meanY > frame.red.meanY ? frame.white.meanY : frame.red.meanY;

  /// Уровень срабатывания каждой лампы. Экраны обязаны показывать именно его,
  /// а не [LampConfig.hitFraction]: при шумной калибровке (и при шумной сцене
  /// в живом отсчёте) реальный порог выше. В режиме эталонов — доли
  /// измеренного отклика, null до калибровки; в живом отсчёте — минимальный
  /// подъём над «полом», null до первого кадра.
  double? get whiteOnLevel => _detector.whiteOnLevel;
  double? get redOnLevel => _detector.redOnLevel;

  /// Диагностика окон живого отсчёта для периодического LAMPDBG.
  String get liveDebugTag => _detector.liveDebugTag;

  /// Можно ли считать удар прямо сейчас и если нет — чего не хватает. Рождается
  /// здесь, а не в UI: половина причин сидит внутри сессии, а оператор у лампы
  /// обязан видеть не «жива ли программа», а «можно ли жать».
  ({bool ready, String why}) get readiness {
    if (!_running) {
      return (ready: false, why: 'Камера остановлена — жми «Пуск»');
    }
    if (_lastLampFrame == null) {
      return (ready: false, why: 'Камера ещё не дала ни одного кадра');
    }
    if (_calibrating) {
      return (
        ready: false,
        why: 'Идёт набор «${_detector.calibrationStep.label}»',
      );
    }
    if (!_detector.canEvaluate) {
      return (ready: false, why: 'Нет калибровки — начни с «1 ФОН»');
    }
    // Живому отсчёту нужно окно темноты: до него решения просто нет.
    final int warmup = _config.liveReference ? _detector.liveWarmupLeft : 0;
    if (warmup > 0) {
      return (ready: false, why: 'Жду тёмный фон, осталось значений: $warmup');
    }
    return (ready: true, why: 'ГОТОВ К РАБОТЕ — считаю удары');
  }

  /// Оценка последнего кадра (score/состояние/неоднозначность). Null, пока
  /// кадры не оцениваются: в режиме эталонов — до калибровки, в живом
  /// отсчёте — до первого кадра.
  LampEvaluation? get lastEvaluation => _lastEvaluation;

  /// Последний сырой кадр (для отладочного дампа ориентации). Null до первой
  /// капли с камеры.
  RawLampFrame? get rawFrame => _lastFrame;

  /// Экстрактор признаков этого кадра — нужен демо, чтобы сохранить кадр в RGB.
  FeatureExtractor get extractor => _extractor;

  /// Рубильник измерителя признаков: `null` — штатный Dart-измеритель,
  /// значение — подставленный сторонний датчик.
  ///
  /// Смена ТОЛЬКО меняет способ измерения: пороги, калибровка и CSV при этом
  /// остаются прежними, а они набраны числами прежнего измерителя. Поэтому
  /// вызывающая сторона обязана при каждом переключении сбросить калибровку и
  /// перезаписать CSV — в демо это делает пунк меню «Датчик». Сам сеттер
  /// нарочно ничего не стирает: пакет не знает, сравнивают датчики или
  /// продолжают прогон.
  FeatureExtractor get sensorExtractor => _extractor;

  set sensorExtractor(FeatureExtractor? value) {
    final FeatureExtractor next = value ?? _dartExtractor;
    if (identical(next, _extractor)) {
      return;
    }
    _extractor = next;
    // Конфиг мог смениться, пока измеритель был другой: свежий получает
    // текущий, а не тот, с которым его создавали.
    _extractor.config = _config;
    _notify(force: true);
  }

  /// История score по времени — для графика «повторное попадание».
  List<ScorePoint> get scoreHistory => diagnostics.scores;

  LampStatus get status => LampStatus(
    running: _running,
    calibrating: _calibrating,
    calibration: _detector.calibrationProgress,
    isCalibrated: _detector.isCalibrated,
    whiteLit: _whiteLit,
    redLit: _redLit,
    whiteHits: _whiteHits,
    redHits: _redHits,
    sessionId: sessionId,
    recordingCsv: _recordingCsv,
    state: _machine.state,
    csvPath: csvRecorder.filePath,
    stepResult: _stepResult,
    completedSteps: _detector.completedCalibrationSteps,
    phaseSeconds: phaseSeconds,
    calibrationHint: calibrationHint,
    calibrationError: _stepError,
    settling: settling,
    exposureLocked: exposureLocked,
    overexposed: _overexposed,
  );

  /// Загружает сохранённые ROI, baseline и пороги. Вызывать до [start].
  Future<void> loadSettings() async {
    _roi = settings.readRoi() ?? _roi;
    final LampConfig? storedConfig = settings.readConfig();
    if (storedConfig != null) {
      _config = storedConfig;
      _extractor.config = storedConfig;
      _detector.config = storedConfig;
      diagnostics.isolateThresholdMs = storedConfig.analysisIsolateThresholdMs;
    }
    final LampBaseline? baseline = settings.readBaseline();
    if (baseline != null && !baseline.isCalibrated) {
      // Калибровка v1 (одно состояние «фон») не содержит эталонов лампы, а v2 с
      // недобранными шагами не решает. Совместимости нет: это одна потерянная
      // калибровка при переходе формата, как после правки ориентации кадра.
      await settings.clearBaseline();
      _report(
        'Сохранённая калибровка отвергнута (формат v${baseline.version}, '
        'нужен v${LampBaseline.currentVersion}): пересними три шага кнопками.',
        isError: false,
      );
    } else if (baseline != null) {
      final int ageMin = DateTime.now()
          .difference(
            DateTime.fromMillisecondsSinceEpoch(baseline.capturedAtMs),
          )
          .inMinutes;
      if (ageMin <= _config.baselineMaxAgeMinutes) {
        _detector.setBaseline(baseline);
        // База измерений — та, при которой калибровка снималась, а не та, которую
        // задаст первый попавшийся кадр: иначе смена света между прогонами
        // прошла бы незамеченной ровно в том случае, ради которого проверка и
        // написана.
        _exposure.remember(
          ns: baseline.exposureTimeNs,
          gain: baseline.sensorSensitivity,
        );
      } else {
        _report(
          'Старая калибровка отброшена (возраст $ageMin мин): освещение могло смениться.',
          isError: false,
        );
      }
    }
    final String? storedSession = settings.readSessionId();
    if (storedSession != null) {
      _machine.startSession(storedSession);
    }
    _notify(force: true);
  }

  /// Запуск: подписка на кадры + попытка отправить недоставанные события.
  Future<void> start() async {
    if (_running || _disposed) {
      return;
    }
    // Живой отсчёт не должен тянуть «ноль» из прошлого прогона: между стопом и
    // стартом могли сменить сцену (другие картинки, свет, положение телефона).
    _detector.resetTracking();
    // База по экспозиции остаётся только у реальной калибровки: без неё её
    // всё равно не с чем сверять, а первый кадр нового прогона задаст условия
    // сам.
    if (!_detector.isCalibrated) {
      _exposure.clear();
    }
    _statusSub ??= source.status.listen(_onSourceStatus);
    _framesSub ??= source.frames.listen(_onFrame);
    try {
      await source.start();
      _running = true;
      _notify(force: true);
    } on Object catch (e) {
      _report('Старт камеры: $e');
    }
    // Стоп закрывает файл, но не отменяет выбор оператора «писать CSV».
    if (_running && _csvEnabled && !_recordingCsv) {
      await setRecordingCsv(true);
    }
    await deliverPending();
  }

  /// Полная остановка: поток кадров и камера освобождаются, повторный [start]
  /// работает без перезапуска приложения.
  Future<void> stop() async {
    _running = false;
    await _persistBaseline();
    await source.stop();
    await _framesSub?.cancel();
    await _statusSub?.cancel();
    _framesSub = null;
    _statusSub = null;
    if (_recordingCsv) {
      await csvRecorder.stop();
      _recordingCsv = false;
    }
    // Кадров больше не будет, поэтому незавершённый набор закрывается ошибкой,
    // а не остаётся висеть навсегда.
    if (_calibrating) {
      final StateError e = StateError(
        'Сессия остановлена: набор «${_detector.calibrationStep.label}» прерван',
      );
      _calibrating = false;
      _settleLeft = 0;
      _stepResult = '';
      _calibrationCompleter?.completeError(e);
      _calibrationCompleter = null;
    }
    _notify(force: true);
  }

  /// Снять один шаг калибровки — по его собственной кнопке.
  ///
  /// Ни автоматики, ни набора «по времени», ни ожидания лампы: сцену приводит
  /// в нужное состояние человек и в тот же момент жмёт кнопку шага. Шагу всё
  /// равно, что было до него и что будет после, — поэтому порядок не обязателен
  /// и переснять можно что-то одно: недостающие состояния подставляются из
  /// рабочей калибровки ([LampDetector.seedCalibration]), а стираются лишь
  /// переснимаемый шаг и всё, что было снято позже него
  /// ([LampDetector.goToCalibrationStep]).
  ///
  /// Первые [calibrationSettleFrames] кадров и первые [calibrationSettleTime]
  /// выбрасываются: переходные кадры руки и автоэкспозиции после
  /// перелоксировки в эталон не попадают.
  ///
  /// Бросает [CalibrationException], если шаг шумел, а на «красной» — если
  /// лампа вообще не увидна: повторять тогда нужно ровно этот шаг, а не всю
  /// калибровку. Прежняя модель остаётся рабочей, пока не набран последний
  /// шаг, — до него события считаются по ней.
  Future<CalibrationReport> calibrateStep(CalibrationStep step) {
    if (!_running) {
      return Future<CalibrationReport>.error(
        StateError('Сессия не запущена: сначала «Пуск»'),
      );
    }
    if (_calibrating) {
      if (step == _detector.calibrationStep && _calibrationCompleter != null) {
        // Та же кнопка во время набора: второго набора не запускаем, ждём этот.
        return _calibrationCompleter!.future;
      }
      // Другая кнопка нажалась посреди набора: прерываем его, а не заставляем
      // человека ждать тридцать кадров чужого шага.
      _calibrating = false;
      _settleLeft = 0;
      _calibrationCompleter?.completeError(
        StateError('Набор «${_detector.calibrationStep.label}» прерван'),
      );
      _calibrationCompleter = null;
    }
    final LampBaseline? previous = _detector.baseline;
    if (previous != null && previous.isCalibrated) {
      _detector.seedCalibration(previous);
    }
    if (step != CalibrationStep.background &&
        !_detector.completedCalibrationSteps.contains(
          CalibrationStep.background,
        )) {
      // Сравнивать лампу пока не с чем: без фона шаг не измеряет отклик, а
      // «готовая» калибровка из одного состояния была бы молча слепой.
      // Проверка до goToStep — иначе отказ ещё и стёр бы снятые состояния.
      return Future<CalibrationReport>.error(
        StateError('Фон ещё не снят: начни с кнопки «1 ФОН»'),
      );
    }
    _detector.goToCalibrationStep(step);
    _calibrating = true;
    _settleLeft = calibrationSettleFrames;
    _phaseStartedAt = DateTime.now();
    _clipWarned = false;
    if (step == CalibrationStep.background) {
      // Убавить свет из-за пересвета можно только на фоне: на последующих
      // шагах экспозиция обязана стоять там же, где её заперли при «1 ФОН».
      _clipCorrectionsLeft = maxClipCorrections;
    }
    _stepResult = '';
    _stepError = '';
    // Свет перед набором обязательно ставится на место: шаг, собранный на
    // уплывающей автоэкспозиции, — это будущие двойные срабатывания.
    unawaited(_relockExposure());
    _calibrationCompleter = Completer<CalibrationReport>();
    _notify(force: true);
    return _calibrationCompleter!.future;
  }

  /// Отпустить и снова запереть экспозицию, если источник это умеет.
  Future<void> _relockExposure() async {
    final ExposureControl? light = _light;
    if (light == null) {
      return;
    }
    try {
      await light.relockExposure();
    } on Object catch (e) {
      _report('Экспозиция: $e', isError: false);
    }
    _notify(force: true);
  }

  /// Шаг «фон» набран на пересвете: убираем экспозицию и переснимаем шаг.
  Future<void> _reduceExposureAndRestart(CalibrationStep step) async {
    final ExposureControl? light = _light;
    if (light == null) {
      return;
    }
    final bool done = await light.reduceExposure();
    if (!done) {
      return;
    }
    // Экспозиция сменилась — всё, что по этому шагу уже собрано, недействительно.
    _detector.discardCalibrationStep();
    _settleLeft = calibrationSettleFrames;
    _phaseStartedAt = DateTime.now();
    _report(
      'Пересвет убран, «${step.label}» набирается заново',
      isError: false,
    );
    _notify(force: true);
  }

  /// Забыть калибровку целиком: и недобранный набор, и рабочую базу, и «пол»
  /// живого отсчёта.
  ///
  /// Раньше у метода был флаг `dropBaseline` со значением по умолчанию `false`,
  /// и кнопка «Сброс калибровки» в демо звала именно его: стирались только
  /// недобранные кадры, а решение продолжало приниматься по прежней базе.
  /// Оператор нажимал «сброс» и видел, что счётчик идёт как ни в чём не
  /// бывало (замерено 20.11.2026). Прервать текущий шаг и так можно, начав
  /// другой, — поэтому неотключаемого «мягкого» режима здесь больше нет.
  ///
  /// Счётчики ударов не обнуляются: за них отвечает отдельный ⟳, иначе сброс
  /// калибровки посреди серии терял бы саму серию.
  void resetCalibration() {
    _calibrating = false;
    _settleLeft = 0;
    final Completer<CalibrationReport>? pending = _calibrationCompleter;
    _calibrationCompleter = null;
    pending?.completeError(StateError('Калибровка сброшена'));
    // Единственный честный путь: `startCalibration` стирает собранные
    // состояния И базу (`clearBaseline`), а с базой — гистерезис, состояние
    // «горит» и окно живого отсчёта. Отдельный `clearCalibration` для этого не
    // годился: он трогал только набор.
    _detector.startCalibration();
    unawaited(settings.clearBaseline());
    _stepResult = '';
    _stepError = '';
    _notify(force: true);
  }

  /// Воспроизведение записанного CSV без камеры: те же детектор и автомат.
  ///
  /// В режиме эталонов три состояния собираются из строк с меткой шага
  /// калибровки (колонка `calibration_step`) — так запись и ведётся; можно
  /// передать готовый [baseline]. В режиме живого отсчёта калибровка не нужна,
  /// поэтому воспроизводится любой файл: «ноль» берётся из тех же строк.
  Future<List<HitEvent>> replayCsv(
    String csvContent, {
    LampBaseline? baseline,
  }) async {
    final List<FeatureCsvRow> rows = FeatureCsv.decode(csvContent);
    if (rows.isEmpty) {
      return const <HitEvent>[];
    }
    final LampDetector detector = LampDetector(_config);
    if (!_config.liveReference) {
      detector.setBaseline(baseline ?? _calibrateFrom(rows));
    } else if (baseline != null) {
      detector.setBaseline(baseline);
    }
    final HitStateMachine machine = HitStateMachine(sessionId: 'replay');
    final List<HitEvent> events = <HitEvent>[];
    for (final FeatureCsvRow row in rows) {
      events.addAll(machine.onEvaluation(detector.evaluate(row.toLampFrame())));
    }
    return events;
  }

  /// Разбор ОДНОЙ записи (CSV v4 и старых форматов): сколько событий
  /// она набрала и какие у неё длительности провалов и пауз.
  ///
  /// Главное здесь — второе: по записи измеряются числа, которыми задают
  /// [LampConfig.offConfirmMs]; без записи их придумывать нечем (см. журнал §11).
  RunAnalysis analyzeRecording(String csvContent) =>
      RunAnalyzer.analyze(csvContent, base: _config);

  /// Калибровка из CSV по меткам шагов: по три состояния, как на живом стенде.
  LampBaseline _calibrateFrom(List<FeatureCsvRow> rows) {
    final Map<CalibrationStep, List<LampFrame>> byStep =
        <CalibrationStep, List<LampFrame>>{};
    for (final FeatureCsvRow row in rows) {
      final CalibrationStep? step = CalibrationStep.fromCsvTag(
        row.calibrationStep,
      );
      if (step == null) {
        continue;
      }
      (byStep[step] ??= <LampFrame>[]).add(row.toLampFrame());
    }
    if (byStep.isEmpty) {
      throw ArgumentError(
        'в CSV нет меток шагов калибровки (колонка calibration_step): файл '
        'записан старой сборкой либо это рабочий прогон. Передайте baseline в '
        'replayCsv.',
      );
    }
    final List<String> missing = CalibrationStep.values
        .where(
          (CalibrationStep s) => (byStep[s] ?? const <LampFrame>[]).isEmpty,
        )
        .map((CalibrationStep s) => '«${s.label}» (шаг ${s.number})')
        .toList();
    if (missing.isNotEmpty) {
      throw ArgumentError(
        'в CSV нет кадров ${missing.join(', ')} — калибровку '
        'по такому файлу не восстановить',
      );
    }
    return LampBaseline(
      background: LampCalibration.stateFrom(
        byStep[CalibrationStep.background]!,
        _config,
        step: CalibrationStep.background,
      ),
      whiteOn: LampCalibration.stateFrom(
        byStep[CalibrationStep.whiteOn]!,
        _config,
        step: CalibrationStep.whiteOn,
      ),
      redOn: LampCalibration.stateFrom(
        byStep[CalibrationStep.redOn]!,
        _config,
        step: CalibrationStep.redOn,
      ),
      capturedAtMs: rows.last.timestampMs,
      // Условия света восстановляются по первому кадру набора: рабочий прогон
      // по этому baseline должен сброситься, если экспозиция ушла, а без метки
      // он бы молча считал по чужой шкале.
      exposureTimeNs: rows.first.exposureTimeNs,
      sensorSensitivity: rows.first.sensorSensitivity,
    );
  }

  void updateRoi(RoiLayout layout, {bool persist = false}) {
    final bool moved = !_sameRoi(_roi, layout);
    _roi = layout;
    if (moved) {
      _dropCalibrationOnRoiMove();
    }
    if (persist) {
      unawaited(settings.writeRoi(layout));
    }
    _notify(force: true);
  }

  /// Рамки изменились — значит все собранные измерения считались по другим
  /// пикселям: и фон, и эталон, и «пол» живого отсчёта. Оставлять их нельзя:
  /// прогон продолжится по калибровке, снятой с чужого места в кадре (тот же
  /// дефект, что §6.11 журнала), а кнопка пересъёма подставила бы её же числа
  /// как ранее снятые. Сброс срабатывает один раз на перетаскивание — дальше
  /// данных для сброса уже нет.
  void _dropCalibrationOnRoiMove() {
    final bool hasCalibration =
        _calibrating ||
        _detector.completedCalibrationSteps.isNotEmpty ||
        _detector.isCalibrated;
    if (hasCalibration) {
      resetCalibration();
      _report(
        'Рамки сдвинулись — калибровка сброшена. Наведи и жми «1 ФОН»',
        isError: false,
      );
      return;
    }
    // Калибровки нет, сбрасывать нечего — но «пол» живого отсчёта всё равно
    // набран по ПРЕЖНИМ пикселям. Это не мелочь: в живом режиме считать можно
    // и без калибровки, поэтому оператор, наводящий рамки уже после «Пуск»,
    // получал окно, снятое с фона и с чужого места кадра, и единственный способ
    // это починить был «Стоп» → «Пуск» (ЖУРНАЛ §6.21).
    if (_config.liveReference) {
      relearnLight();
    }
  }

  /// Экспозиция сменилась посреди прогона.
  ///
  /// Это тот же дефект, что и со сдвинутыми рамками, только замаскированный:
  /// числа в кадре те же, а света под ними другое количество. Решение то же —
  /// сброс, а не «пересчёт»: и эталоны, и «пол» живого отсчёта набраны при
  /// прежней выдержке и новый свет не описывают. Кадр, на котором смена
  /// поймана, не оценивается: скачок сенсора неотличим от вспышки, а одно
  /// событие, рождённое автоэкспозицией, дороже потерянного кадра.
  void _onExposureBasisLost(
    ({int? ns, double? gain}) previous,
    LampFrame frame,
  ) {
    final bool wasCalibrated = _detector.isCalibrated;
    resetCalibration();
    final String shift = ExposureGuard.describe(
      aNs: previous.ns,
      aGain: previous.gain,
      bNs: frame.exposureTimeNs,
      bGain: frame.sensorSensitivity,
    );
    _report(
      'Экспозиция сменилась ($shift)'
      '${wasCalibrated ? ': калибровка сброшена' : ': набор начинается заново'} — '
      'жми «${CalibrationStep.background.key}» и сними три шага при этом свете.',
    );
  }

  static bool _sameRoi(RoiLayout a, RoiLayout b) {
    return a.white.left == b.white.left &&
        a.white.top == b.white.top &&
        a.white.width == b.white.width &&
        a.white.height == b.white.height &&
        a.red.left == b.red.left &&
        a.red.top == b.red.top &&
        a.red.width == b.red.width &&
        a.red.height == b.red.height;
  }

  Future<void> saveRoi() => settings.writeRoi(_roi);

  Future<void> saveCalibration() async {
    final LampBaseline? baseline = _detector.baseline;
    if (baseline != null) {
      await settings.writeBaseline(baseline);
    }
  }

  Future<void> saveConfig() => settings.writeConfig(_config);

  /// Смена порогов на лету (подбор по CSV).
  void applyConfig(LampConfig config) {
    _config = config;
    _extractor.config = config;
    _detector.config = config;
    diagnostics.isolateThresholdMs = config.analysisIsolateThresholdMs;
    _notify(force: true);
  }

  /// Принудительное соответствие превью <-> кадр (если авто-расчёт не угадал
  /// ориентацию сенсора на конкретном устройстве).
  void setFrameMapping(int quarterTurns, {bool mirror = false}) {
    final FrameSource target = source;
    if (target is FrameMappingControl) {
      (target as FrameMappingControl).setFrameMapping(
        quarterTurns,
        mirror: mirror,
      );
    }
    _notify(force: true);
  }

  /// Новая сессия: новый sessionId, нумерация событий с 1, счётчики в нуль.
  Future<void> newSession() async {
    final String id = const Uuid().v4();
    _machine.startSession(id);
    _detector.resetTracking();
    _whiteHits = 0;
    _redHits = 0;
    _whiteLit = false;
    _redLit = false;
    diagnostics.resetCounters();
    await settings.writeSessionId(id);
    _notify(force: true);
  }

  /// Сброс счётчиков без смены сессии.
  void resetCounters() {
    _whiteHits = 0;
    _redHits = 0;
    _machine.reset();
    _detector.resetTracking();
    diagnostics.resetCounters();
    _notify(force: true);
  }

  /// Перемерить свет заново, НЕ трогая счётчики.
  ///
  /// Единственное, что делает оператор после «Пуск» — наводит рамки на колпаки.
  /// При этом «пол» живого отсчёта уже набран по другим пикселям и по другому
  /// свету (засветка, горящая соседняя лампа, рука перед объективом), и
  /// единственный известный способ это сбросить был — «Стоп» и «Пуск» снова.
  /// Здесь ровно этот сброс, но без потери прогона: счётчики, id сессии и
  /// номера событий остаются, уходят только окно «пола», гистерезис и состояние
  /// «горит» (а с ним и залипший канал). Пока окно не наберётся, [readiness]
  /// честно пишет сколько допустимых значений осталось.
  ///
  /// Калибровку не трогает: она привязана к рамкам, а не к моменту нажатия.
  void relearnLight() {
    _detector.resetTracking();
    // Лока экспозиции без калибровки держаться не за что: первый же кадр нового
    // набора задаст условия, и прежняя база стала бы выдумкой.
    if (!_detector.isCalibrated) {
      _exposure.clear();
    }
    _report(
      'Перемеряю свет. Держи лампы погашенными, '
      'осталось значений: ${_detector.liveWarmupLeft}',
      isError: false,
    );
    _notify(force: true);
  }

  /// Включает/выключает запись CSV признаков.
  Future<void> setRecordingCsv(bool on) async {
    _csvEnabled = on;
    if (on == _recordingCsv) {
      return;
    }
    _recordingCsv = on;
    if (on) {
      await csvRecorder.start(sessionId);
      _report('Запись CSV: ${csvRecorder.filePath}', isError: false);
    } else {
      await csvRecorder.stop();
      _report('CSV сохранён: ${csvRecorder.filePath}', isError: false);
    }
    _notify(force: true);
  }

  /// Защита от очереди кадров: если обработка идёт, кадр пропускается.
  DateTime? _prevFrameAt;
  double _avgGapMs = 0;

  void _onFrame(RawLampFrame frame) {
    diagnostics.onCameraFrame(frame.receivedAt);
    // _busy в синхронной обработке всегда false, поэтому реальные потери кадров
    // ловим по разрывам во времени между кадрами.
    final DateTime? prev = _prevFrameAt;
    _prevFrameAt = frame.receivedAt;
    if (prev != null) {
      final double gap =
          frame.receivedAt.difference(prev).inMicroseconds / 1000.0;
      if (_avgGapMs > 0 && gap > _avgGapMs * 2.2) {
        final int lost = (gap / _avgGapMs).round() - 1;
        for (int i = 0; i < lost; i++) {
          diagnostics.onFrameDropped();
        }
      } else {
        _avgGapMs = _avgGapMs == 0 ? gap : _avgGapMs * 0.95 + gap * 0.05;
      }
    }
    _lastFrame = frame;
    if (_busy) {
      diagnostics.onFrameDropped();
      return;
    }
    _busy = true;
    try {
      _processFrame(frame);
    } on Object catch (e) {
      _report('Обработка кадра: $e');
    } finally {
      _busy = false;
    }
  }

  void _processFrame(RawLampFrame frame) {
    diagnostics.beginAnalysis();

    final LampFrame lampFrame = _extractor.extract(frame, _roi, source.mapping);
    // Шаг, к которому относится этот кадр: после завершения шага он уже
    // указал на следующий, а в CSV метка обязана остаться на набранных кадрах.
    final CalibrationStep stepAtStart = _detector.calibrationStep;
    // Кадры стабилизации эталоном не становятся и в CSV с меткой шага не
    // пишутся: иначе replayCsv восстановит состояние по переходным кадрам.
    final bool settlingNow = settling;
    final bool wasCalibrating = _calibrating && !settlingNow;
    _overexposed =
        lampFrame.white.meanY >= clipLuma || lampFrame.red.meanY >= clipLuma;
    // Свет — часть измерения, а не обстановка: и эталоны, и «пол» живого
    // отсчёта сняты при конкретной экспозиции. Поймали смену — кадр не
    // оценивается вовсе (скачок сенсора неотличим от вспышки лампы), а
    // прежние измерения сбрасываются. Кадры стабилизации пропускаются: там
    // экспозиция именно переставляется, и это не смена условий прогона.
    if (!settlingNow) {
      final ({int? ns, double? gain})? lost = _exposure.checkAndAdopt(
        ns: lampFrame.exposureTimeNs,
        gain: lampFrame.sensorSensitivity,
      );
      if (lost != null) {
        _onExposureBasisLost(lost, lampFrame);
        return;
      }
    }
    LampEvaluation? evaluation;
    List<HitEvent> events = const <HitEvent>[];

    if (_calibrating) {
      if (settlingNow) {
        // Первые кадры после старта шага: ещё могут быть переходными (рука на
        // выключателе, автоэкспозиция после перелоксировки), в эталон не идут,
        // но кадр остаётся живым для экрана и диагностики.
        if (_settleLeft > 0) {
          _settleLeft--;
        }
      } else if (stepAtStart == CalibrationStep.background &&
          _overexposed &&
          _clipCorrectionsLeft > 0) {
        // Фон на клиппинге — это слепая калибровка целиком. Один раз за шаг
        // убираем свет и переснимаем фон: пока это единственный шаг, после
        // которого экспозицию менять не поздно.
        _clipCorrectionsLeft--;
        _report(
          'Фон пересвечен (Y=${_clipY(lampFrame).toStringAsFixed(0)}): '
          'убавляю экспозицию и переснимаю фон',
          isError: false,
        );
        unawaited(_reduceExposureAndRestart(stepAtStart));
      } else {
        if (_overexposed && !_clipWarned) {
          _clipWarned = true;
          _report(
            'Пересвет (Y=${_clipY(lampFrame).toStringAsFixed(0)}): в клиппинге нет '
            'ни цвета, ни яркости — этот канал ничего не посчитает. '
            'Закрой лампу плотнее или убавь свет и повтори калибровку.',
            isError: false,
          );
        }
        try {
          final CalibrationReport? report = _detector.addCalibrationFrame(
            lampFrame,
          );
          if (report != null) {
            _calibrating = false;
            _settleLeft = 0;
            _stepResult = report.describe();
            // Шаг принят — строка отказа больше не нужна: по ней кнопка шага
            // снова стала обычной, а не «пересними».
            _stepError = '';
            if (report.baseline != null) {
              unawaited(saveCalibration());
            }
            _report(_stepResult, isError: false);
            _calibrationCompleter?.complete(report);
            _calibrationCompleter = null;
          }
        } on CalibrationException catch (e) {
          // Раньше исключение терялось в _onFrame, а _calibrating оставался true
          // навсегда: кнопка зависала на 30/30.
          _calibrating = false;
          _settleLeft = 0;
          _stepResult = '';
          _stepError = e.brief;
          _report('$e');
          final Completer<CalibrationReport>? pending = _calibrationCompleter;
          _calibrationCompleter = null;
          pending?.completeError(e);
          _notify(force: true);
        }
      }
    } else if (_detector.canEvaluate) {
      evaluation = _detector.evaluate(lampFrame);
      if (evaluation.ambiguous) {
        diagnostics.onAmbiguousFrame();
      }
      if (evaluation.unexplained) {
        diagnostics.onUnexplainedFrame();
      }
      events = _machine.onEvaluation(evaluation);
      _whiteLit = evaluation.whiteLit;
      _redLit = evaluation.redLit;
    }

    _lastLampFrame = lampFrame;
    _lastEvaluation = evaluation;

    diagnostics.endAnalysis();
    diagnostics.onFrameProcessed(
      timestamp: lampFrame.timestamp,
      whiteAmplitude: evaluation?.whiteAmplitude ?? 0,
      redAmplitude: evaluation?.redAmplitude ?? 0,
      residual: evaluation?.residual ?? 0,
      exposureTimeNs: lampFrame.exposureTimeNs,
      sensorSensitivity: lampFrame.sensorSensitivity,
    );

    if (_recordingCsv) {
      // Диагностика привязана к тому же кадру, что и решение. При калибровке
      // живой отсчёт не вызывался, поэтому его поля остаются пустыми, а не
      // повторяют устаревшее состояние предыдущего рабочего кадра.
      final liveReading = evaluation != null && _config.liveReference
          ? _detector.liveReading
          : null;
      final reference = liveReading == null ? null : _detector.liveDiagnostics;
      unawaited(
        csvRecorder.write(
          FeatureCsvRow(
            timestampMs: lampFrame.timestamp.millisecondsSinceEpoch,
            white: lampFrame.white,
            red: lampFrame.red,
            state: _machine.state.name,
            // Всё, чем этот кадр был решён: кольцо, подъём, порог, переходы.
            // Без этих колонок запись не воспроизводит решение детектора, а
            // только его вход.
            whiteRing: lampFrame.whiteRing,
            redRing: lampFrame.redRing,
            whiteRise: evaluation?.whiteAmplitude ?? 0,
            redRise: evaluation?.redAmplitude ?? 0,
            whiteLevel: _detector.whiteOnLevel ?? 0,
            redLevel: _detector.redOnLevel ?? 0,
            whiteLit: evaluation?.whiteLit ?? _whiteLit,
            redLit: evaluation?.redLit ?? _redLit,
            whiteOn: evaluation?.whiteOn ?? false,
            redOn: evaluation?.redOn ?? false,
            whiteOff: evaluation?.whiteOff ?? false,
            redOff: evaluation?.redOff ?? false,
            ambiguous: evaluation?.ambiguous ?? false,
            unexplained: evaluation?.unexplained ?? false,
            exposureTimeNs: lampFrame.exposureTimeNs,
            sensorSensitivity: lampFrame.sensorSensitivity,
            calibrationStep: wasCalibrating ? stepAtStart.csvTag : '',
            whiteNet: liveReading?.whiteNet ?? 0,
            redNet: liveReading?.redNet ?? 0,
            whiteDarkMs: evaluation?.whiteDarkMs ?? 0,
            redDarkMs: evaluation?.redDarkMs ?? 0,
            whiteValid: liveReading?.whiteValid,
            redValid: liveReading?.redValid,
            whiteBelowOff: liveReading?.whiteBelowOff,
            redBelowOff: liveReading?.redBelowOff,
            reference: reference,
          ),
        ),
      );
    }

    if (events.isNotEmpty) {
      unawaited(_handleEvents(events));
    }
    // Теневой способ измерения — самый последний шаг: он вызывается, когда
    // решение по кадру уже принято и события отправлены, поэтому повлиять на
    // автомат у него нет никакого пути. Падение тени ронять прогон не имеет
    // права: сравниваем способ, а не проверяем устойчивость к нему.
    final ShadowProbe? probe = shadowProbe;
    if (probe != null) {
      try {
        probe(
          ShadowInput(
            raw: frame,
            roi: _roi,
            mapping: source.mapping,
            frame: lampFrame,
            evaluation: evaluation,
          ),
        );
      } on Object catch (e) {
        if (!_shadowWarned) {
          _shadowWarned = true;
          _report('Теневой измеритель отключён: $e');
        }
        shadowProbe = null;
      }
    }
    frameTick.value++;
    _notify();
  }

  /// События сначала пишутся в SQLite, потом идут в UI и в очередь доставки.
  Future<void> _handleEvents(List<HitEvent> events) async {
    final Stopwatch saveTimer = Stopwatch()..start();
    for (final HitEvent event in events) {
      try {
        await repository.save(event);
        diagnostics.onSaveLatency(saveTimer.elapsed);
        diagnostics.onEvent();
        if (event.color == HitColor.white) {
          _whiteHits++;
        } else {
          _redHits++;
        }
        _hits.add(event);
      } on Object catch (e) {
        _report('Сохранение события ${event.eventId}: $e');
      }
      saveTimer
        ..reset()
        ..start();
    }
    _notify(force: true);
    await deliverPending();
  }

  /// Последовательная отправка всех недоставанных событий. При первой же
  /// неудаче встаём: события остаются pending и уйдут при следующем запуске.
  Future<void> deliverPending() async {
    final Future<void>? inFlight = _delivery;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> task = _deliverLoop();
    _delivery = task;
    try {
      await task;
    } finally {
      _delivery = null;
    }
  }

  Future<void> _deliverLoop() async {
    while (!_disposed) {
      final List<HitEvent> pending;
      try {
        pending = await repository.pending();
      } on Object catch (e) {
        _report('Чтение pending: $e');
        return;
      }
      if (pending.isEmpty) {
        return;
      }
      for (final HitEvent event in pending) {
        try {
          final DeliveryResult result = await sender.send(event);
          if (!result.success) {
            await repository.markFailed(event.eventId);
            _report(
              'Доставка ${event.eventId} не удалась: ${result.error}',
              isError: false,
            );
            return;
          }
          await repository.markSent(event.eventId);
        } on Object catch (e) {
          await _safeMarkFailed(event.eventId);
          _report('Исключение доставки ${event.eventId}: $e');
          return;
        }
      }
    }
  }

  Future<void> _safeMarkFailed(String eventId) async {
    try {
      await repository.markFailed(eventId);
    } on Object catch (e) {
      _report('markFailed($eventId): $e');
    }
  }

  Future<void> _persistBaseline() async {
    try {
      await saveCalibration();
    } on Object catch (e) {
      _report('Сохранение калибровки: $e');
    }
  }

  void _onSourceStatus(FrameSourceStatus status) {
    _report(status.message, isError: status.isError);
  }

  void _report(String message, {bool isError = true}) {
    _lastErrors.insert(0, message);
    if (_lastErrors.length > maxStoredErrors) {
      _lastErrors.removeRange(maxStoredErrors, _lastErrors.length);
    }
    if (isError) {
      _errors.add(message);
    }
    debugPrint('[lamp_detection] $message');
  }

  /// 30 кадров в секунду — перерисовывать UI на каждый кадр бессмысленно:
  /// уведомляем только когда видимые значения реально изменились.
  void _notify({bool force = false}) {
    final LampStatus s = status;
    final String signature =
        '${s.running}|${s.calibrating}|${s.calibration}|${s.isCalibrated}|'
        '${s.whiteLit}|${s.redLit}|${s.whiteHits}|${s.redHits}|${s.sessionId}|'
        '${s.recordingCsv}|${s.stepResult}|${s.settling}|'
        '${s.calibrationHint}|${s.calibrationError}|${s.exposureLocked}';
    if (!force && signature == _lastSignature) {
      return;
    }
    _lastSignature = signature;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stop();
    diagnostics.dispose();
    await _hits.close();
    await _errors.close();
    frameTick.dispose();
    super.dispose();
  }
}
