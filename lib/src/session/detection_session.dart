import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

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
import '../diagnostics/run_mailer.dart';
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
    this.hasBothOnProfile = false,
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

  /// Снят ли необязательный шаг 4 («обе горят», профиль BOTH_ON в v6 §7). По
  /// нему кнопка ставит ✓ только когда состояние действительно измерено, а не
  /// когда «просто калибровка уже готова».
  final bool hasBothOnProfile;

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
    this.mailer,
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

  /// Отправка готового прогона на почту стенда. `null` — прогоны лежат только
  /// на устройстве, ровно как было до этой возможности: ящик не обязателен
  /// для работы, он обязателен для того, чтобы прогон увидели без кабеля.
  final RunMailer? mailer;

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

  /// Момент последнего «Пуск» — по нему письмо прогона говорит длительность.
  /// `null` между стопом и пуском: прогона, о котором есть что сказать, нет.
  DateTime? _runStartedAt;
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

  /// Считаются ли события: живому отсчёту калибровка не нужна, HSV и режиму
  /// эталонов — нужна (журнал 46).
  bool get canEvaluate => _detector.canEvaluate;

  /// Чему калибровка научила цветовой счёт: одна строка с правилом именования и
  /// разделением в σ, пусто в другом способе. Печатается в отчёте шага и в
  /// LAMPDBG, чтобы «прошло» не выглядело как «научилось».
  String get hsvNaming => _detector.hsvNaming;
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
        CalibrationStep.bothOn => 'Держи обе лампы горящими',
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
      CalibrationStep.bothOn =>
        'Включи обе и жми «${CalibrationStep.bothOn.key}»',
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

  /// Сколько раз кадр просился сразу в обе корзины и был отдан одной
  /// (`LampDetector._oneBasket`). Ноль — правило не пригодилось; каждое
  /// число больше нуля видно в `LAMPDBG both=` и проверяется на прогоне.
  int get doubleBasketFrames => _detector.doubleBasketFrames;

  /// Сколько кадров профиль отверг подъём, который хотел подтвердить
  /// измеренный путь; из них — отвергнутых как отражение соседней лампы; и
  /// сколько кадров остались недоказанными. Печатаются в `LAMPDBG` как `rej=`
  /// и `unk=`: по ним на прогоне видно, что отказ отражения работает, а не
  /// молча съедает счёт — ровно то, чем принимается v6 §5.
  int get refusedFrames => _detector.refusedFrames;
  int get reflectionRefusals => _detector.reflectionRefusals;
  int get unknownFrames => _detector.unknownFrames;

  /// Чем кадр решает по профилям — одна строка с числами и причиной. Пусто в
  /// другом способе счёта.
  String get profileDecision => _detector.profileDecision;

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
      // При цветовом счёте калибровка нужна не для порога, а для имени: без
      // трёх состояний детектор нашёл бы вспышку, но не имел бы права сказать,
      // чья она (журнал 46).
      return (
        ready: false,
        why: _config.hsvReference
            ? 'HSV-счёт ждёт калибровку: «1 ФОН» → «2 БЕЛАЯ» → «3 КРАСНАЯ»'
            : 'Нет калибровки — начни с «1 ФОН»',
      );
    }
    // Скользящим способам (живому и HSV) нужно окно темноты: до него решения
    // просто нет.
    final int warmup = _config.countMode == LampCountMode.etalon
        ? 0
        : _detector.liveWarmupLeft;
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
    hasBothOnProfile: _detector.hasBothOnProfile,
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
      _runStartedAt = DateTime.now();
      _notify(force: true);
    } on Object catch (e) {
      _report('Старт камеры: $e');
    }
    // Что не дошло в прошлый раз, уходит при первом же контакте с сетью: не
    // раньше и не позже, чем сам запуск.
    unawaited(mailer?.resendPending() ?? Future<void>.value());
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
    // Файл закрыт, всё на месте — прогон уходит на почту сам. Не ждём: сеть
    // может лежать, а «Стоп» обязан вернуть экран человеку у лампы.
    // Прогон считается законченным ровно один раз: повторный «Стоп» не должен
    // присылать второе письмо о том же самом.
    final DateTime? runStartedAt = _runStartedAt;
    _runStartedAt = null;
    if (mailer != null && runStartedAt != null) {
      unawaited(_sendRunPackage(runStartedAt));
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

  /// Письмо готового прогона на почту стенда.
  ///
  /// Делается после «Стоп», когда CSV закрыт и в нём есть всё. Ошибка сети —
  /// не ошибка прогона: пакет остаётся в очереди и дойдёт при следующем
  /// пуске (см. [RunMailer]), поэтому у лампы человек ничего не жмёт и ничего
  /// не теряет.
  Future<void> _sendRunPackage(DateTime started) async {
    final RunMailer? mailer = this.mailer;
    final String? csvPath = csvRecorder.filePath;
    if (mailer == null || csvPath == null) {
      return;
    }
    try {
      final io.File csv = io.File(csvPath);
      final String csvText = csv.existsSync() ? await csv.readAsString() : '';
      final DateTime stopped = DateTime.now();
      final LampBaseline? shot = baseline;
      await mailer.submit(
        assembleRunPackage(
          runId: '${sessionId}_${_stamp(stopped)}',
          subject: _runSubject(stopped),
          body: _runBody(started, stopped, csvText),
          textFiles: <String, String>{
            'features.csv': csvText,
            'config.json': jsonEncode(_config.toJson()),
            'roi.json': jsonEncode(_roi.toJson()),
            'log.txt': lastErrors.reversed.join('\n'),
            if (shot != null) 'baseline.json': jsonEncode(shot.toJson()),
          },
        ),
      );
    } on Object catch (e) {
      _report('Отправка прогона: $e');
    }
  }

  /// Тема письма: по ней прогон находится в почте, не открывая вложений.
  String _runSubject(DateTime stopped) {
    final DiagnosticsSnapshot d = diagnostics.snapshot;
    return 'LAMP ${_stampHuman(stopped)} | $_modeShort | '
        'W=$whiteHits R=$redHits | rej $refusedFrames/$reflectionRefusals '
        'unk $unknownFrames | ${d.framesProcessed} кадр. | sess $sessionId';
  }

  /// Что это за прогон, словами. Сюда кладётся и сверка ОБОИХ режимов по этой
  /// же записи: на стенде её никто не пересчитает, а вопрос «не потеряли ли
  /// новый способ что-нибудь» должен быть виден в письме, а не после
  /// скачивания.
  String _runBody(DateTime started, DateTime stopped, String csvText) {
    final DiagnosticsSnapshot d = diagnostics.snapshot;
    final LampBaseline? shot = baseline;
    final List<String> lines = <String>[
      'Прогон $sessionId',
      '  старт ${_stampHuman(started)}, стоп ${_stampHuman(stopped)}, '
          'длительность ${stopped.difference(started).inSeconds} с',
      '  файл: ${csvRecorder.filePath ?? 'не известен'}',
      '',
      'Чем считали: $_modeShort',
      '  калибровка: ${isCalibrated ? 'есть' : 'НЕТ'}'
          '${shot == null ? '' : ', версия ${shot.version} '
                    '(профили распределений — с версии 4)'}',
      '  снятые шаги: ${_detector.completedCalibrationSteps.map((CalibrationStep s) => s.label).join(', ')}',
      '  шаг «обе горят»: ${_detector.hasBothOnProfile ? 'снят' : 'не снят'}',
      '',
      'Кадры: всего ${d.framesProcessed}, потеряно ${d.droppedFrames}, '
          'fps камеры ${d.cameraFps.toStringAsFixed(1)}, '
          'анализ ${d.avgAnalysisMs.toStringAsFixed(2)} мс '
          '(макс ${d.maxAnalysisMs.toStringAsFixed(1)} мс)',
      '  спорные кадры ${d.ambiguousFrames}, необъяснённые ${d.unexplainedFrames}',
      '',
      'События за прогон: белая $whiteHits, красная $redHits',
      'Профили (v6): отвергнуто подъёмов $refusedFrames, из них как '
          'отражение соседней лампы $reflectionRefusals, кадров без '
          'доказательства $unknownFrames, кадров «в обе корзины» '
          '$doubleBasketFrames',
      '  чем решил последний кадр: ${profileDecision.isEmpty ? '—' : profileDecision}',
      '',
      _abLines(csvText),
      '',
      'Отличия порогов от значений по умолчанию: $_configDelta',
      '',
      'Как читать: features.csv открывается Excel; колонки 87…90 — уверенность '
          'и подозрение обеих ламп (v6), 69…86 — новые признаки света. '
          'baseline.json обязателен, чтобы пересчитать режим с профилими '
          'офлайн: без него письмо описывает решение, но не повторяет его.',
      'Чего в письме нет: разметки истины — какие лампы горели на самом деле '
          'знает только человек или панель. Пока её нет, прогон годится на '
          '«сколько отказов и где», но не на приёмку v6.',
    ];
    return lines.join('\r\n');
  }

  /// Та же запись, решённая обоими цветовыми режимами — то, чем принимается
  /// v6 §7. Не считается, если CSV пустой или кривой: письмо обязано уйти и
  /// без этой строчки.
  String _abLines(String csvText) {
    if (csvText.isEmpty) {
      return 'Сверка режимов по этой записи: CSV пуст — считать нечего.';
    }
    try {
      final RunAb ab = RunAnalyzer.analyzeBothModes(
        csvText,
        base: _config,
        baseline: baseline,
      );
      return <String>[
        'Пересчёт этой же записи двумя способами (офлайн, тем же кодом):',
        '  hsv (прежний измеренный): белая ${ab.plain.whiteEvents}, '
            'красная ${ab.plain.redEvents}',
        '  hsv + профили (v6)        : белая ${ab.profiled.whiteEvents}, '
            'красная ${ab.profiled.redEvents}',
        '  ${ab.verdict}',
      ].join('\r\n');
    } on Object catch (e) {
      return 'Сверка режимов по этой записи не посчиталась: $e';
    }
  }

  /// Имя пакета в очереди: метка времени без разделителей.
  static String _stamp(DateTime at) =>
      at.toIso8601String().replaceAll(RegExp(r'[:.TZ]'), '');

  /// Человекочитаемая метка «26.11.2026 14:32:05».
  static String _stampHuman(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.day)}.${two(at.month)}.${at.year} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  /// Короткое имя способа — то же, что в `LAMPDBG mode=`.
  String get _modeShort => switch (_config.countMode) {
    LampCountMode.hsv => 'hsv',
    LampCountMode.hsvCalibration => 'hsv+prof',
    LampCountMode.etalon => 'etalon',
    LampCountMode.live => 'live',
  };

  /// Только те числа, которые стенд менял относительно сборки: по ним видно,
  /// что решение принималось не на дефолтах.
  String get _configDelta {
    final Map<String, Object?> base = const LampConfig().toJson();
    final List<String> diff = <String>[];
    for (final MapEntry<String, Object?> e in _config.toJson().entries) {
      if (base.containsKey(e.key) && base[e.key] != e.value) {
        diff.add('${e.key}=${e.value}');
      }
    }
    return diff.isEmpty ? 'нет' : diff.join(', ');
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
  /// передать готовый [baseline]. В живом отсчёте калибровка не нужна, поэтому
  /// воспроизводится любой файл: «ноль» берётся из тех же строк.
  ///
  /// HSV-счёту калибровка нужна: без неё не выучено правило, и имена вспышек
  /// взяться не откуда (журнал 46). Поэтому [baseline] по умолчанию — калибровка
  /// текущей сессии; файл, снятый до неё, воспроизведётся без имён.
  Future<List<HitEvent>> replayCsv(
    String csvContent, {
    LampBaseline? baseline,
  }) async {
    final List<FeatureCsvRow> rows = FeatureCsv.decode(csvContent);
    if (rows.isEmpty) {
      return const <HitEvent>[];
    }
    final LampDetector detector = LampDetector(_config);
    if (_config.countMode == LampCountMode.etalon) {
      detector.setBaseline(baseline ?? _calibrateFrom(rows));
    } else {
      final LampBaseline? use =
          baseline ?? (_config.hsvReference ? _detector.baseline : null);
      if (use != null) {
        detector.setBaseline(use);
      }
    }
    final HitStateMachine machine = HitStateMachine(sessionId: 'replay');
    final List<HitEvent> events = <HitEvent>[];
    for (final FeatureCsvRow row in rows) {
      events.addAll(machine.onEvaluation(detector.evaluate(row.toLampFrame())));
    }
    return events;
  }

  /// Разбор ОДНОЙ записи (CSV v5 и старых форматов): сколько событий
  /// она набрала и какие у неё длительности провалов и пауз.
  ///
  /// Главное здесь — второе: по записи измеряются числа, которыми задают
  /// [LampConfig.offConfirmMs]; без записи их придумывать нечем (см. журнал §11).
  ///
  /// Разбор идёт тем же режимом, каким считалась сама запись (способ счёта
  /// текущей конфигурации): HSV-прогон, пересчитанный по яркости, дал бы другой
  /// счёт, который нельзя сравнить ни с чем (журнал §11.12). Калибровка берётся
  /// у сессии: HSV-счёт называется именно по ней, и без неё разбор не
  /// запускается вовсе ([RunAnalyzer.analyze] бросает [ArgumentError]).
  RunAnalysis analyzeRecording(String csvContent) => RunAnalyzer.analyze(
    csvContent,
    base: _config,
    mode: _config.countMode,
    baseline: _detector.baseline,
  );

  /// Та же запись, решённая ОБОИМИ режимами v6 подряд — `hsv` (прежнее
  /// измеренное дерево) и `hsvCalibration` (с сверкой по профилям).
  ///
  /// Нужна ровно для приёмки v6 §7: профили имеют право отнять события, и до
  /// того как это станет рабочим поведением, разница обязана быть померена на
  /// ОДНОЙ записи, а не на двух разных стендах. Калибровка берётся у сессии —
  /// та же, которой считали вживую.
  RunAb analyzeRecordingAb(String csvContent) => RunAnalyzer.analyzeBothModes(
    csvContent,
    base: _config,
    baseline: _detector.baseline,
  );

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
      if (persist) {
        // Программная смена рамок (не палец): запись и сразу же сброс,
        // ровно как было до наводки «на лету».
        unawaited(settings.writeRoi(layout));
        _dropCalibrationOnRoiMove();
      } else {
        // Перетаскивание. Сброс отложен до отпускания пальца: событий за
        // время наводки всё равно не будет (кадры в это время не считаются,
        // см. [setRoiAiming]), а на каждый палец-апдейт их приходят десятки —
        // прежний сброс глушил и панель, и поток именно ими.
        _roiResetPending = true;
      }
    }
    _notify(force: true);
  }

  /// Палец ведёт рамку (`true`) или отпустил (`false`).
  ///
  /// Пока идёт наводка, кадры НЕ анализируются. Причина не в бережности:
  /// анализ одного кадра — десятки миллисекунд на том же потоке, где живёт
  /// жест, и каждый обработанный кадр втискивается между двумя событиями
  /// пальца, из-за чего рамки едут рывками. Считать в момент, когда зоны
  /// поменяли место, всё равно нечем: набор по ним будет сброшен.
  void setRoiAiming(bool aiming) {
    _roiAiming = aiming;
  }

  bool _roiAiming = false;

  /// Есть ли незакрытый сброс после наводки рамок.
  bool _roiResetPending = false;

  /// Конец наводки: сохранить рамки и ровно один раз сбросить то, что набрано
  /// по ПРЕЖНИМ пикселям. Ручная программа (`updateRoi(persist: true)`) этим
  /// не пользуется — там нет «конца жеста».
  Future<void> commitRoi() async {
    await settings.writeRoi(_roi);
    if (!_roiResetPending) {
      return;
    }
    _roiResetPending = false;
    _dropCalibrationOnRoiMove();
  }

  /// Рамки изменились — значит все собранные измерения считались по другим
  /// пикселям: и фон, и эталон, и «пол» живого отсчёта. Оставлять их нельзя:
  /// прогон продолжится по калибровке, снятой с чужого места в кадре (тот же
  /// дефект, что §6.11 журнала), а кнопка пересъёма подставила бы её же числа
  /// как ранее снятые. При наводке пальцем сброс происходит ОДИН раз, на
  /// отпускании ([commitRoi]), а не на каждый кадр жеста.
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
    if (_config.countMode != LampCountMode.etalon) {
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

  /// Способ счёта. Спецификация v6 §MODES требует ровно двух: `hsv` (цветовой
  /// счёт, профили калибровки на решение не влияют) и `hsvCalibration` (тот же
  /// счёт плюс сверка кадра с профилями OFF/ON/spill). Оба обязаны идти с
  /// калибровкой ровно так же, как режим эталонов: по трём состояниям
  /// называется имя вспышки (слово заказчика «будем только с калибровкой
  /// работать», журнал 46). `etalon` и `live` в перечислении остались только
  /// ради сохранённых старых настроек — наружу их больше нет (v6 §MODES: «no
  /// additional detection modes»).
  ///
  /// Гистерезис и окно «пола» сбрасываются при любом переключении: у способов
  /// разные единицы (доля отклика, яркость, доля цвета), и окно, набранное в
  /// одних, не годится для порога в других — тот же дефект, что §6.21, только
  /// замаскированный переключателем.
  Future<void> setCountMode(LampCountMode mode) async {
    if (_config.countMode == mode) {
      return;
    }
    applyConfig(_config.withCountMode(mode));
    _detector.resetTracking();
    await saveConfig();
    _report(switch (mode) {
      LampCountMode.etalon =>
        'Счёт по калибровке: сними три шага кнопками, до этого удары не считаются',
      LampCountMode.live =>
        'Счёт живой: калибровка не нужна, держи лампы погашенными пару секунд',
      LampCountMode.hsv =>
        'HSV: сними три шага калибровки — по ним называется, какая лампа '
            'вспыхнула; профилями кадр НЕ сверяется, это ровно измеренное '
            'дерево v5',
      LampCountMode.hsvCalibration =>
        'HSV + калибровка: тот же счёт плюс сверка кадра с профилями '
            'OFF/ON/spill — уверенность, отказ отражению и недоказанный кадр; '
            'до «3 КРАСНАЯ» удары не считаются',
    }, isError: false);
  }

  /// Пресеты порога счёта, по которым ходит рубильник в меню.
  ///
  /// Различаются ОДНИМ числом — множителем σ окна, то есть тем, насколько
  /// подъём обязан перевешивать шум фона: `6` — как измерено на стенде, `2` —
  /// полупрозрачный шум, `0` — «в лоб», любой подъём минимум на
  /// [LampConfig.referenceMinRise] над «полом». Множитель читают ОБА скользящих
  /// способа: живой ([LiveReference]) и HSV (её уровень — `referenceNoiseSigmas ×
  /// σ` того же окна), поэтому пункт живёт в меню и там,
  /// и там, а не только в «живом». Больше одного фактора за раз менять нельзя:
  /// непонятно, что именно дало результат.
  static const List<({String label, double sigmas})> liveSensitivityPresets =
      <({String label, double sigmas})>[
        (label: 'строгая · 6σ', sigmas: 6),
        (label: 'мягкая · 2σ', sigmas: 2),
        (label: 'в лоб · без σ', sigmas: 0),
      ];

  /// Имя текущего пресета; «свой», если множитель σ задан вручную.
  String get liveSensitivityLabel {
    for (final ({String label, double sigmas}) p in liveSensitivityPresets) {
      if (_config.referenceNoiseSigmas == p.sigmas) {
        return p.label;
      }
    }
    return 'свой · ${_config.referenceNoiseSigmas}σ';
  }

  /// Следующий пресет порога по кругу. Окно не пересобирается: множитель σ
  /// применяется к каждому кадру, а «пол» от него не зависит.
  Future<void> cycleLiveSensitivity() async {
    final List<({String label, double sigmas})> presets =
        liveSensitivityPresets;
    final int current = presets.indexWhere(
      (p) => p.sigmas == _config.referenceNoiseSigmas,
    );
    final ({String label, double sigmas}) next =
        presets[(current + 1) % presets.length];
    applyConfig(_config.copyWith(referenceNoiseSigmas: next.sigmas));
    await saveConfig();
    _report('Порог счёта: ${next.label}', isError: false);
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
    if (_roiAiming) {
      // Кадр уходит в никуда намеренно: пока палец ведёт рамку, считать нечем,
      // зато у жеста остаётся весь поток. Потеря честная — она видна в
      // диагностике, а не прячется.
      diagnostics.onFrameDropped();
      return;
    }
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

    if (_roiResetPending) {
      // Рамки сдвинули, а «палец отпущен» до нас не дошло (экран закрыт
      // посреди жеста). Считать кадр по прежним измерениям нельзя, поэтому
      // сброс догоняется здесь, а не ждёт следующего коммита.
      _roiResetPending = false;
      _dropCalibrationOnRoiMove();
    }

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
              // Для цветового счёта калибровка — не «разрешение работать», а
              // учитель имён: без неё детектор стоит ([readiness]), а с ней
              // оператор обязан увидеть, ЧЕМУ она научилась. Строка
              // `hsvNaming` — единственное место, где видно разделение в σ:
              // без неё «калибровка прошла» и «калибровка ничему не научила»
              // выглядят одинаково (журнал 46).
              final String naming = _detector.hsvNaming;
              if (naming.isNotEmpty) {
                _stepResult = '$_stepResult · $naming';
              }
              // Профили v6 §8 — то, чем кадр теперь отказывает отражению. По
              // слову «готово» этого не видно: строка говорит, набраны ли
              // распределения и сколько отказов они уже дали.
              final String profiles = _detector.profileDecision;
              if (profiles.isNotEmpty) {
                _stepResult = '$_stepResult · $profiles';
              }
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
      // скользящие отсчёты не вызывались, поэтому их поля остаются пустыми, а
      // не повторяют устаревшее состояние предыдущего рабочего кадра.
      final liveReading =
          evaluation != null && _config.countMode != LampCountMode.etalon
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
            // Чем кадр решили по профилям калибровки (v6 §13). Null здесь
            // означает «не считалось» (калибровка без профилей, другой способ
            // счёта), а не «уверенность нулевая».
            whiteConfidence: evaluation?.whiteConfidence,
            redConfidence: evaluation?.redConfidence,
            whiteSuspicion: evaluation?.whiteSuspicion,
            redSuspicion: evaluation?.redSuspicion,
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
