import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'opencv_runner.dart';
import 'sim_frame_source.dart';

/// Тестовая панель: мигание картинок состояний и два эталонных числа.
///
/// Никакой детекции картинки здесь нет — камера, анализ пикселей, БД и
/// настройки живут на настоящем детекторе. Панель считает сама «правильный
/// ответ» двумя способами:
///
/// * **сцены** — сколько раз лампа действительно вспыхнула;
/// * **правило** — сколько насчитал бы детектор при идеальном кадре, если
///   прогнать ту же последовательность сцен через настоящие классы
///   `LampDetector` + `HitStateMachine` с заданной частотой обработки.
///
/// Второе число отвечает на вопрос «виновато правило или камера»: если
/// «правило» уже меньше «сцен», стимул в принципе не считывается на этой
/// частоте, и требовать от телефона совпадения бессмысленно. Если «правило»
/// равно «сценам», а на телефоне меньше — потеря там, в кадре и в fps.
///
/// Наборов картинок два (`SimStyle`, переключаются в `⚙`) и оба рисуют одну и
/// ту же геометрию: круги — чистый стимул для проверки тайминга, а «настоящий
/// свет» — те же круги, поверх которых лежит свечение, измеренное с фото
/// реальной лампы (ядро, ореол, заливка фона), чтобы проверить, какую долю
/// пикселей детектор видит от настоящей лампы.
///
/// Кнопки «Белая»/«Красная» в ряду со стартом держат лампу включённой столько,
/// сколько нужно. Это не про тайминги, а про калибровку детектора («держим белую
/// включённой», потом «держим красную») и про пороги без гонки цикла. Нажатие
/// кнопки останавливает мигание: владеет кадром всегда кто-то один.
///
/// Параметры `auto*` приходят из переменных окружения (см. main.dart) и нужны
/// для полностью автоматического прогона: панель стартует сама, с задержкой,
/// чтобы успеть откалибровать детектор по выключенным лампам.
///
/// `autoOpenCv` добавляет к панели второй, независимый прогон: тот же самый
/// конвейер кадров на коротком плане сцен, но с подключённым теневым
/// измерителем на OpenCV. Открыть его кнопкой или переменной окружения можно
/// в любой момент — он гасит мигание, владеет кадром сам и ничего в решении не
/// меняет: сравнение двух способов измерения существует ровно настолько.
class SimHomePage extends StatefulWidget {
  const SimHomePage({
    super.key,
    this.autoStart = false,
    this.autoRandom = false,
    this.autoSpeed,
    this.autoStartDelayMs = 5000,
    this.startClean = false,
    this.autoOpenCv = false,
    this.openCvReportPath,
  });

  final bool autoStart;
  final bool autoRandom;

  /// slow | medium | fast (null — оставить текущую).
  final String? autoSpeed;
  final int autoStartDelayMs;

  /// Стартовый режим «только кадр»: управление скрыто, лампы на весь экран.
  final bool startClean;

  /// Прогнать сравнение способов измерения сразу после загрузки картинок.
  final bool autoOpenCv;

  /// Куда положить текст сравнения; null — временная папка.
  final String? openCvReportPath;

  @override
  State<SimHomePage> createState() => _SimHomePageState();
}

class _SimHomePageState extends State<SimHomePage> {
  final SimFrameSource _source = SimFrameSource();
  String _message = 'загрузка картинок…';

  bool _clean = false;
  bool _scanning = false;
  int _cycleStep = 0;
  Timer? _cycleTimer;
  Timer? _autoTimer;
  Timer? _shadowTimer;

  /// Плановый момент СЛЕДУЮЩЕГО переключения панели. Расписание абсолютное:
  /// таймер всегда опаздывает на задержку планировщика, и в цепочке «следующий
  /// таймер заводится от уже опоздавшего момента» это опоздание ползло бы шаг за
  /// шагом. См. `_runCycleStep`.
  int _cycleDueMs = 0;

  // Эталон: сколько раз каждая лампа реально мигнула.
  int _flashWhite = 0;
  int _flashRed = 0;

  // Счёт тем же правилом, что и детектор: настоящие LampDetector +
  // HitStateMachine, накормленные идеальным сигналом (см. _frameFor). Числа
  // панели получаются из того же кода, что и числа телефона, поэтому их можно
  // сравнивать напрямую.
  int _ruleWhite = 0;
  int _ruleRed = 0;

  /// Частота обработки, к/с. Это НЕ частота камеры: `_busy` в сессии роняет
  /// кадры, так что реальное число меньше cameraFps. Оно до сих пор не
  /// измерено, поэтому значение подбирается слайдером, а не взято из кода.
  int _ruleFps = 10;

  /// Те же `onConfirmFrames` / `offConfirmFrames`, что в `LampConfig` по
  /// умолчанию. Меняются слайдером, чтобы видеть, где правило теряет вспышку.
  int _ruleOn = 2;
  int _ruleOff = 3;

  static const int _ruleFpsDefault = 10;
  static const int _ruleOnDefault = 2;
  static const int _ruleOffDefault = 3;

  /// Идеальные величины сигнала — замеры живой камеры, взятые из README
  /// («Оценка»): вспышка белой даёт ΔwhiteFrac ≈ 0.12, красной — ΔredFrac ≈
  /// 0.42. Фон — ровно ноль и без шума, то есть уровень срабатывания остаётся
  /// `hitFraction`, а гистерезисная зона не достигается вовсе.
  /// Эмуляция проверяет только тайминг правила, фотометрию — нет.
  static const double _liveWhiteDeltaFrac = 0.12;
  static const double _liveRedDeltaFrac = 0.42;

  /// Способ счёта панели назван прямо: рабочим по умолчанию теперь считается
  /// HSV (журнал 46), а панель эмулирует идеальную калибровку по яркости —
  /// цветовых рядов в ней нет, и HSV-детектор такой baseline не читает.
  LampDetector _ruleDetector = LampDetector(
    const LampConfig(liveReference: false, hsvReference: false),
  );
  final HitStateMachine _ruleMachine = HitStateMachine(
    sessionId: 'panel-rule',
    idGenerator: () => 'rule',
  );

  /// Вся последовательность шагов текущего прогона: сцена и её длительность.
  /// Нужна, чтобы пересчитать «правило» после смены fps или подтверждения,
  /// не перезапуская мигание.
  final List<({SimScene scene, Duration hold})> _timeline =
      <({SimScene scene, Duration hold})>[];

  /// Часы эмуляции: шаг вперёд на каждый обработанный кадр. Нужны только для
  /// `detectedAt` внутри детектора, поэтому и отвязаны от реального времени —
  /// но обязаны начинаться с начала прогона, иначе после очередного пересчёта
  /// уедут в будущее.
  int _clockMs = DateTime.now().millisecondsSinceEpoch;
  int _runStartMs = DateTime.now().millisecondsSinceEpoch;

  // Скорость перелистывания.
  _Speed _speed = _Speed.medium;

  // ── Сравнение двух способов измерения (OpenCV только теневой) ────────────
  //
  // Создаётся один раз на панель: накопленные пары кадров и есть результат,
  // а пересоздавать его — значит терять числа прогона.
  OpenCvShadowRunner? _shadow;
  bool _shadowBusy = false;
  List<String> _shadowLines = <String>[];
  String _shadowSummary = 'сравнение ещё не запускалось';

  // Режим: false — фиксированный цикл, true — случайная лампа и рваные паузы.
  bool _random = false;
  final Random _rng = Random();

  // Ручное удержание лампы кнопками «Белая»/«Красная»: сцена, выставленная
  // вручную (всегда `off`, `white` или `red`), и момент, когда она загорелась.
  // `_manualSinceMs == 0` означает «ручного отрезка нет» — в этом состоянии
  // кадр принадлежит циклу или просто выключен.
  SimScene _manualScene = SimScene.off;
  int _manualSinceMs = 0;

  // Порядок сцен: выключено → белая → выключено → красная → выключено.
  // Сцены «обе сразу» в цикле нет: по уточнению заказчика лампы одновременно
  // не загораются, и такая вспышка была бы нереалистичным стимулом.
  static const List<SimScene> _sequence = <SimScene>[
    SimScene.off,
    SimScene.white,
    SimScene.off,
    SimScene.red,
  ];

  Duration get _offHold => switch (_speed) {
    _Speed.slow => const Duration(milliseconds: 2500),
    _Speed.medium => const Duration(milliseconds: 1200),
    _Speed.fast => const Duration(milliseconds: 600),
  };

  Duration get _flashHold => switch (_speed) {
    _Speed.slow => const Duration(milliseconds: 700),
    _Speed.medium => const Duration(milliseconds: 250),
    _Speed.fast => const Duration(milliseconds: 120),
  };

  // Случайная длительность вокруг базовой: base * [lo..hi].
  Duration _jitter(Duration base, double lo, double hi) => Duration(
    milliseconds: (base.inMilliseconds * (lo + _rng.nextDouble() * (hi - lo)))
        .round(),
  );

  @override
  void initState() {
    super.initState();
    _clean = widget.startClean;
    _random = widget.autoRandom;
    switch (widget.autoSpeed) {
      case 'slow':
        _speed = _Speed.slow;
      case 'fast':
        _speed = _Speed.fast;
      case 'medium':
        _speed = _Speed.medium;
      default:
        break;
    }
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await _source.load();
      // Правило калибруется сразу, а не только с первым «Стартом»: ручное
      // удержание лампы способно закрыть свой отрезок и пересчитать правило до
      // того, как цикл вообще запускался, а `LampDetector.evaluate` на
      // некалиброванном детекторе бросает StateError.
      _resetRule();
      debugPrint(
        'PANEL картинки: '
        '${_source.hasPhotoSet ? 'круги + настоящий свет' : 'только круги'}',
      );
      setState(() => _message = 'Нажми «Старт».');
      if (widget.autoStart) {
        debugPrint(
          'PANEL auto-start через ${widget.autoStartDelayMs}ms '
          'speed=${_speed.name} random=$_random clean=$_clean',
        );
        _autoTimer = Timer(Duration(milliseconds: widget.autoStartDelayMs), () {
          if (mounted) {
            _startScan();
          }
        });
      }
      if (widget.autoOpenCv) {
        // Задержка та же, что у автостарта мигания, а вместе два флага ничего
        // не дают: сравнение останавливает цикл, потому что владеет кадром само.
        debugPrint(
          'PANEL OPENCV автопрогон через ${widget.autoStartDelayMs}ms',
        );
        _shadowTimer = Timer(
          Duration(milliseconds: widget.autoStartDelayMs),
          () {
            if (mounted) {
              unawaited(_runShadowComparison());
            }
          },
        );
      }
    } on Object catch (e) {
      setState(() => _message = 'Не удалось загрузить картинки: $e');
    }
  }

  void _startScan() {
    _autoTimer?.cancel();
    _autoTimer = null;
    // Новый прогон начинается с чистого листа: незакрытый ручной отрезок
    // сбрасывается без записи в таймлайн, вместе со всеми счётчиками.
    _dropManual();
    _cycleStep = 0;
    _cycleDueMs = 0;
    _flashWhite = 0;
    _flashRed = 0;
    _timeline.clear();
    _runStartMs = DateTime.now().millisecondsSinceEpoch;
    _clockMs = _runStartMs;
    _resetRule();
    setState(() {
      _scanning = true;
      _message = 'Мигание…';
    });
    _runCycleStep();
  }

  void _stopScan() {
    _cycleTimer?.cancel();
    _cycleTimer = null;
    _cycleDueMs = 0;
    // Цикл остановлен, но рука пользователя могла остаться в кадре: закрытый
    // сейчас отрезок попадает в таймлайн, чтобы «правило» не разошлось с
    // «сценами» из-за потерянной вспышки.
    _flushManualSegment();
    _source.setScene(SimScene.off);
    setState(() {
      _scanning = false;
      _message = 'Остановлено.';
    });
  }

  void _resetFlashes() {
    // Сброс эталона гасит и ручную лампу: иначе на экране одна сцена, а нули
    // в обоих числах относятся к другой.
    _dropManual();
    _source.setScene(SimScene.off);
    _timeline.clear();
    _runStartMs = DateTime.now().millisecondsSinceEpoch;
    _clockMs = _runStartMs;
    _resetRule();
    setState(() {
      _flashWhite = 0;
      _flashRed = 0;
    });
  }

  // ── Счёт по правилу детектора ────────────────────────────────────────────

  /// Период одного обработанного кадра при выбранной частоте обработки.
  int get _framePeriodMs => (1000 / _ruleFps).round();

  /// Пересоздаёт детектор с текущими `onConfirmFrames` / `offConfirmFrames` и
  /// калибрует его в три идеальных состояния: фон, «держат белую», «держат
  /// красную». σ = 0 означает «шума нет», поэтому уровень срабатывания остаётся
  /// ровно `hitFraction`, а амплитуда 1.0 = «панель показывает столько же,
  /// сколько при замере этой лампы».
  void _resetRule() {
    final LampConfig config = LampConfig(
      onConfirmFrames: _ruleOn,
      offConfirmFrames: _ruleOff,
      // Панель проверяет тайминг правила, а не фотометрию: у неё идеальная
      // калибровка, и «ноль» обязана давать она, а не окно последних кадров.
      liveReference: false,
      // Не по умолчанию, а прямо: идеальный яркостной baseline панели в HSV-
      // способе не читается цветовыми рядами (журнал 46).
      hsvReference: false,
    );
    _ruleDetector = LampDetector(config)
      ..setBaseline(_idealBaseline(config.calibrationFrames));
    _ruleMachine.reset();
    _ruleWhite = 0;
    _ruleRed = 0;
  }

  /// Идеальная рамка для сигнала панели: 100 образцов, «выключенное» состояние
  /// — равномерная яркость 200. При горении лампы измеренная доля рамки
  /// (`_liveWhiteDeltaFrac` / `_liveRedDeltaFrac`) насыщается в 255 — единственная
  /// идеализация реальной вспышки. Вектор решения детектора (восемь яркостных
  /// координат, `LampVector`) строится из `meanY` и `p90Luma`: среднее
  /// поднимается на долю засветившейся части, а p90 упирается в 255, если
  /// засвечено хотя бы 10% рамки (90-е из 100 отсортированных образцов
  /// попадает на засветившийся пиксель). Цветовые доли не участвуют в решении
  /// — они здесь только как запись «каким был этот кадр».
  FrameFeatures _idealBox({
    double whiteFrac = 0,
    double redFrac = 0,
    double litFrac = 0,
  }) =>
      FrameFeatures(
        meanY: 200.0 + litFrac * (255.0 - 200.0),
        p90Luma: litFrac >= 0.10 ? 255.0 : 200.0,
        sampleCount: 100,
        whiteFrac: whiteFrac,
        redFrac: redFrac,
      );

  /// Идеальная калибровка панели. Раньше здесь жил «чёрный фон + выдуманные
  /// пороги»; теперь тот же смысл, но в формате детектора: отклик каждой лампы
  /// измерен, а не задан, поэтому счёт панели считает ровно то же правило, что
  /// и телефон, а не похожее на него. Носитель решения — яркостный вектор
  /// четырёх областей, поэтому идеальный сигнал тоже построен на яркости
  /// (см. [_idealBox]): фон — равномерные рамки 200, «держат лампу» — её
  /// измеренная доля насыщена в 255. Кадр в [_frameFor] собирается той же
  /// формулой, что и соответствующее состояние калибровки, поэтому амплитуда
  /// горящего кадра ровно 1.0 — «панель показывает столько же, сколько при
  /// замере этой лампы».
  LampBaseline _idealBaseline(int calibrationFrames) {
    CalibrationState state({
      double whiteFrac = 0,
      double redFrac = 0,
      double whiteLit = 0,
      double redLit = 0,
    }) =>
        // σ состояний — нули: идеальный сигнал без шума, поэтому ON-уровень
        // остаётся ровно `hitFraction`. (FrameFeatures хранит σ в полях
        // meanY/p90Luma, поэтому «та же рамка» здесь означало бы σ = 200.)
        CalibrationState(
          white: _idealBox(whiteFrac: whiteFrac, litFrac: whiteLit),
          red: _idealBox(redFrac: redFrac, litFrac: redLit),
          whiteSigma: FrameFeatures.zero,
          redSigma: FrameFeatures.zero,
          frameCount: calibrationFrames,
        );
    return LampBaseline(
      background: state(),
      whiteOn: state(
        whiteFrac: _liveWhiteDeltaFrac,
        whiteLit: _liveWhiteDeltaFrac,
      ),
      redOn: state(redFrac: _liveRedDeltaFrac, redLit: _liveRedDeltaFrac),
      capturedAtMs: _clockMs,
    );
  }

  /// Прогон накопленной таймлайна заново — вызывается, когда пользователь
  /// двигает fps или подтверждение: число должно меняться на уже сделанных
  /// вспышках, а не только на будущих.
  void _replayRule() {
    _clockMs = _runStartMs;
    _resetRule();
    for (final ({SimScene scene, Duration hold}) step in _timeline) {
      _advanceRule(step.scene, step.hold);
    }
  }

  /// Кормит детектор кадрами одной сцены. Кадров берётся `длительность / период`
  /// — это ровно то, сколько прошло бы через `_busy` при данной частоте
  /// обработки. Минимум один кадр: сцена длиной меньше периода в реальной
  /// детекции тоже дала бы кадр, а не ноль.
  void _advanceRule(SimScene scene, Duration hold) {
    final int periodMs = _framePeriodMs;
    final int frames = max(1, (hold.inMilliseconds / periodMs).round());
    for (int i = 0; i < frames; i++) {
      _clockMs += periodMs;
      final LampEvaluation evaluation = _ruleDetector.evaluate(
        _frameFor(scene, DateTime.fromMillisecondsSinceEpoch(_clockMs)),
      );
      for (final HitEvent event in _ruleMachine.onEvaluation(evaluation)) {
        if (event.color == HitColor.white) {
          _ruleWhite++;
        } else {
          _ruleRed++;
        }
      }
    }
  }

  LampFrame _frameFor(SimScene scene, DateTime timestamp) {
    final bool whiteLit = scene == SimScene.white || scene == SimScene.both;
    final bool redLit = scene == SimScene.red || scene == SimScene.both;
    // Кадр собирается той же формулой, что и соответствующее состояние
    // идеальной калибровки (_idealBaseline): горящий кадр отличается от фона
    // ровно на калибровочный эталон, амплитуда — ровно 1.0.
    return LampFrame(
      timestamp: timestamp,
      white: _idealBox(
        whiteFrac: whiteLit ? _liveWhiteDeltaFrac : 0,
        litFrac: whiteLit ? _liveWhiteDeltaFrac : 0,
      ),
      red: _idealBox(
        redFrac: redLit ? _liveRedDeltaFrac : 0,
        litFrac: redLit ? _liveRedDeltaFrac : 0,
      ),
    );
  }

  bool get _isDefaultView =>
      _source.style == SimStyle.drawn &&
      _source.brightness == 1.0 &&
      _source.shiftX == 0 &&
      _source.shiftY == 0 &&
      _ruleFps == _ruleFpsDefault &&
      _ruleOn == _ruleOnDefault &&
      _ruleOff == _ruleOffDefault;

  String _viewSummary() =>
      '${_source.style.name}, '
      '×${_source.brightness.toStringAsFixed(1)}, '
      'сдвиг ${_source.shiftX.toStringAsFixed(2)} / '
      '${_source.shiftY.toStringAsFixed(2)}, '
      'правило $_ruleFps к/с on=$_ruleOn off=$_ruleOff';

  /// Диалог настроек панели. Отдельных рядов кнопок не добавляет: это одна
  /// кнопка `tune` во втором ряду. Слайдеры действуют сразу — панель видна за
  /// маской диалога, поэтому значение подбирается по живому кадру.
  ///
  /// Настройки действуют до перезапуска окна: в панели нет хранилища, а
  /// тянуть его ради шести слайдеров смысла нет.
  ///
  /// Нижние три слайдера относятся не к картинке, а к счёту: они меняют
  /// `LampConfig` эмуляции и пересчитывают уже сделанные вспышки
  /// (`_replayRule`), поэтому число «по правилу» видит эффект сразу.
  Future<void> _openViewSettings() async {
    double brightness = _source.brightness;
    double shiftX = _source.shiftX;
    double shiftY = _source.shiftY;
    SimStyle style = _source.style;

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            // Одно изменение — две перерисовки: подписи слайдеров внутри
            // диалога и картинку панели за ним.
            void apply(void Function() change) {
              setDialogState(change);
              setState(
                () => _source.setView(
                  brightness: brightness,
                  shiftX: shiftX,
                  shiftY: shiftY,
                ),
              );
            }

            // Правила живут в полях состояния, а не в локальных переменных
            // диалога: их читает эмуляция счёта, и ей нужен пересчёт всего
            // уже пройденного прогона.
            void applyRule(void Function() change) {
              setDialogState(change);
              setState(_replayRule);
            }

            // Смена набора картинок счёт не трогает: эталон считается по
            // сценам, а сцены остаются те же. Меняется только то, что увидит
            // камера, — рамки при этом остаются на месте, а живой отсчёт
            // (режим телефона по умолчанию) смену набора переживает сам: «пол»
            // набирается заново из новых кадров. Об этом пишет строка в лог.
            void applyStyle(SimStyle next) {
              if (!_source.setStyle(next)) {
                return;
              }
              setDialogState(() => style = next);
              setState(() {});
              debugPrint(
                'PANEL стиль=${next.name} — счёт по сценам прежний, '
                'рамки те же; живой отсчёт калибровку не требует',
              );
            }

            return AlertDialog(
              title: const Text('Показ ламп и счёт по правилу детектора'),
              content: SizedBox(
                width: 360,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Что видит камера',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SegmentedButton<SimStyle>(
                        segments: const <ButtonSegment<SimStyle>>[
                          ButtonSegment<SimStyle>(
                            value: SimStyle.drawn,
                            label: Text('Круги'),
                          ),
                          ButtonSegment<SimStyle>(
                            value: SimStyle.photo,
                            label: Text('Настоящий свет'),
                          ),
                        ],
                        selected: <SimStyle>{style},
                        showSelectedIcon: false,
                        onSelectionChanged: _source.hasPhotoSet
                            ? (Set<SimStyle> s) => applyStyle(s.first)
                            : null,
                      ),
                      Text(
                        _source.hasPhotoSet
                            ? '«Настоящий свет» — кружки нарисованные, а свет и '
                                  'вид выключенного колпака измерены с фото: '
                                  'ядро, ореол и то, как он заливает фон. '
                                  'Геометрия та же, что у кругов (720×1280), '
                                  'поэтому рамки остаются на месте. '
                                  'Калибровку снимать заново не нужно: живой '
                                  'отсчёт на телефоне сам набирает «пол» из '
                                  'новых кадров (в режиме эталонов — да, нужна).'
                            : 'Набор assets/photo/*.png не найден — вариант '
                                  'недоступен.',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      _sliderRow(
                        label: 'Яркость вспышки',
                        value: brightness,
                        min: 1.0,
                        max: 2.5,
                        divisions: 15,
                        text: '×${brightness.toStringAsFixed(1)}'
                            '${brightness == 1.0 ? ' (как в PNG)' : ''}',
                        onChanged: (double v) => apply(() => brightness = v),
                      ),
                      _sliderRow(
                        label: 'Положение по горизонтали',
                        value: shiftX,
                        min: -0.5,
                        max: 0.5,
                        divisions: 20,
                        text: shiftX.toStringAsFixed(2),
                        onChanged: (double v) => apply(() => shiftX = v),
                      ),
                      _sliderRow(
                        label: 'Положение по вертикали',
                        value: shiftY,
                        min: -0.5,
                        max: 0.5,
                        divisions: 20,
                        text: shiftY.toStringAsFixed(2),
                        onChanged: (double v) => apply(() => shiftY = v),
                      ),
                      const Text(
                        'Сдвиг — в долях самой картинки: 0 = центр, '
                        '±0.5 = край экрана. Фон («обе выключены») ярче не '
                        'становится, растёт только вспышка, поэтому калибровка '
                        'от яркости не ездит.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const Divider(),
                      const Text(
                        'Счёт по правилу детектора',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      _sliderRow(
                        label: 'Частота обработки',
                        value: _ruleFps.toDouble(),
                        min: 5,
                        max: 30,
                        divisions: 25,
                        text: '$_ruleFps к/с (кадр $_framePeriodMs мс)',
                        onChanged: (double v) =>
                            applyRule(() => _ruleFps = v.round()),
                      ),
                      _sliderRow(
                        label: 'Подтверждение включения',
                        value: _ruleOn.toDouble(),
                        min: 1,
                        max: 6,
                        divisions: 5,
                        text: '$_ruleOn подряд кадров',
                        onChanged: (double v) => applyRule(() => _ruleOn = v.round()),
                      ),
                      _sliderRow(
                        label: 'Подтверждение гашения',
                        value: _ruleOff.toDouble(),
                        min: 1,
                        max: 6,
                        divisions: 5,
                        text: '$_ruleOff подряд кадров',
                        onChanged: (double v) =>
                            applyRule(() => _ruleOff = v.round()),
                      ),
                      const Text(
                        'Эмуляция гоняет смены сцен панели через настоящие '
                        'LampDetector и HitStateMachine с идеальным сигналом. '
                        'Частота обработки пока не измерена — подбери её по '
                        'замеру с телефона. Пороги, шум и засветка здесь '
                        'отсутствуют, поэтому число «по правилу» — потолок: '
                        'детектор не может насчитать больше.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    applyStyle(SimStyle.drawn);
                    apply(() {
                      brightness = 1.0;
                      shiftX = 0;
                      shiftY = 0;
                    });
                    applyRule(() {
                      _ruleFps = _ruleFpsDefault;
                      _ruleOn = _ruleOnDefault;
                      _ruleOff = _ruleOffDefault;
                    });
                  },
                  child: const Text('Сбросить'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Готово'),
                ),
              ],
            );
          },
        );
      },
    );

    debugPrint('PANEL настройки ${_viewSummary()}');
  }

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String text,
    required ValueChanged<double> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('$label: $text', style: const TextStyle(fontSize: 13)),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: text,
        onChanged: onChanged,
      ),
    ],
  );

  void _runCycleStep() {
    if (!mounted) {
      return;
    }
    final SimScene scene;
    final Duration hold;
    if (_random) {
      // Чётные шаги — «выключено», нечётные — случайная лампа; паузы рваные.
      // «Обе сразу» тут нет: настоящие лампы одновременно не загораются.
      if (_cycleStep.isEven) {
        scene = SimScene.off;
        hold = _jitter(_offHold, 0.5, 1.5);
      } else {
        scene = _rng.nextBool() ? SimScene.white : SimScene.red;
        hold = _jitter(_flashHold, 0.6, 1.8);
      }
    } else {
      scene = _sequence[_cycleStep % _sequence.length];
      hold = scene == SimScene.off ? _offHold : _flashHold;
    }
    _source.setScene(scene);
    final int switchedAt = DateTime.now().millisecondsSinceEpoch;
    // Отсчёт следующего переключения — от ПЛАНОВОГО момента этого, а не от
    // фактического: иначе опоздание каждого таймера прибавляется к опозданию
    // предыдущего, и через полминуты панель переключается на сотни
    // миллисекунд позже, чем записано в `_timeline`. Правило пересчитывает
    // именно таймлайн, поэтому расхождение превращалось в «1 включение —
    // 2 события».
    final int plannedStart = _cycleDueMs == 0 ? switchedAt : _cycleDueMs;
    final int driftMs = switchedAt - plannedStart;
    final int due = plannedStart + hold.inMilliseconds;
    _cycleDueMs = due;
    debugPrint(
      'PANEL t=$switchedAt plan=$plannedStart drift=${driftMs}ms '
      'step=$_cycleStep scene=${scene.name} hold=${hold.inMilliseconds}ms',
    );
    // Таймер — это намерение, а не событие на экране. Реальный фронт вспышки
    // попадает в следующий кадр композитора, поэтому для размеров offMinMs /
    // onMinMs нужен именно момент отрисовки, а не `t=` выше.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
        'PANEL present switchedAt=$switchedAt '
        'painted=${DateTime.now().millisecondsSinceEpoch} scene=${scene.name}',
      );
    });
    setState(() {
      _countFlash(scene);
      // То же самое, но через правило детектора: шаг копится в таймлайне,
      // чтобы пересчёт при смене fps/подтверждения не требовал нового прогона.
      _addStep(scene, hold);
    });
    _logCounts();
    _cycleTimer = Timer(
      Duration(milliseconds: max(1, due - switchedAt)),
      () {
        _cycleStep++;
        _runCycleStep();
      },
    );
  }

  /// Один шаг таймлайна: сцена с её длительностью, и сразу то же самое —
  /// правилу детектора. Так «по правилу» всегда видит ровно те смены сцен,
  /// которые панель действительно показала: и шагами цикла, и вручную
  /// удержанными лампами (_flushManualSegment).
  void _addStep(SimScene scene, Duration hold) {
    _timeline.add((scene: scene, hold: hold));
    _advanceRule(scene, hold);
  }

  /// Оба эталонных числа в той же шкале, что и `PANEL t=`: по ним видно,
  /// теряло ли правило вспышку уже на идеальном сигнале.
  void _logCounts() {
    debugPrint(
      'PANEL счёт эталон W=$_flashWhite R=$_flashRed '
      'правило W=$_ruleWhite R=$_ruleRed '
      '(fps=$_ruleFps кадр=${_framePeriodMs}ms on=$_ruleOn off=$_ruleOff)',
    );
  }

  /// Эталон по сценам: сколько раз каждая лампа действительно вспыхнула.
  /// Счётчики независимые: если в кадр всё-таки попадёт `both` (в цикле его нет —
  /// настоящие лампы одновременно не горят, а такая сцена доступна только
  /// из лабораторного `SimScene.both`), это две вспышки, по одной на каждую
  /// лампу. Второе число, «по правилу», считается отдельно — в `_advanceRule`.
  void _countFlash(SimScene scene) {
    if (scene == SimScene.white || scene == SimScene.both) {
      _flashWhite++;
    }
    if (scene == SimScene.red || scene == SimScene.both) {
      _flashRed++;
    }
  }

  // ── Ручное удержание лампы ──────────────────────────────────────────────

  /// Кнопки «Белая»/«Красная»: включить лампу и держать, сколько нужно, —
  /// ровно это просят шаги калибровки детектора «держим белую включённой» и
  /// «держим красную включённой», а заодно замер порогов без спешки цикла.
  ///
  /// Лампы взаимоисключающие, как в цикле и в случайном режиме: настоящие
  /// одновременно не загораются, поэтому вторая нажатая кнопка гасит первую, а
  /// `SimScene.both` кнопкам недоступен. Повторное нажатие той же кнопки гасит
  /// её. Кадром владеет кто-то один, поэтому нажатие останавливает мигание.
  void _toggleManual(SimScene target) {
    final bool turningOff = _manualScene == target;
    if (_scanning) {
      _stopScan();
    }
    // Прежняя ручная вспышка закрывается со своей реальной длительностью.
    _flushManualSegment();
    if (turningOff) {
      setState(() => _message = 'Ручной режим: ${_lampWord(target)} погашена.');
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    _manualScene = target;
    _manualSinceMs = now;
    _countFlash(target);
    _source.setScene(target);
    setState(() => _message = 'Ручной режим: ${_lampWord(target)} горит.');
    debugPrint('PANEL manual t=$now scene=${target.name} — держим до второго нажатия');
  }

  /// Закрывает текущий ручной отрезок. Его длительность известна только теперь,
  /// в момент смены сцены, поэтому отрезок уезжает в таймлайн и в правило здесь,
  /// а не в `_toggleManual`. Следом обязателен шаг «выключено»: без гашения
  /// `HitStateMachine` осталась бы в состоянии «горит», и следующая вспышка той
  /// же лампы не дала бы нового события — то есть число «по правилу» молча
  /// отставало бы от эталона. Длительность паузы берётся как у цикла: кадр в
  /// этот момент действительно выключен, а правилу нужно лишь набрать
  /// `offConfirmFrames` подряд.
  void _flushManualSegment() {
    if (_manualSinceMs == 0) {
      return;
    }
    final SimScene scene = _manualScene;
    final Duration hold = Duration(
      milliseconds: max(
        1,
        DateTime.now().millisecondsSinceEpoch - _manualSinceMs,
      ),
    );
    _manualSinceMs = 0;
    _manualScene = SimScene.off;
    // Кадр тоже уходит в «выключено»: это и есть то гашение, которое мы только
    // что посчитали правилом.
    _source.setScene(SimScene.off);
    _addStep(scene, hold);
    _addStep(SimScene.off, _offHold);
    debugPrint(
      'PANEL manual закрыт scene=${scene.name} '
      'hold=${hold.inMilliseconds}ms + пауза ${_offHold.inMilliseconds}ms',
    );
    _logCounts();
  }

  /// Забывает ручной отрезок, ничего не считая: новый прогон и сброс эталона
  /// начинают с нуля, и незакрытая вспышка не должна оставаться в таймлайне.
  void _dropManual() {
    _manualSinceMs = 0;
    _manualScene = SimScene.off;
  }

  String _lampWord(SimScene scene) =>
      scene == SimScene.white ? 'белая' : 'красная';

  // ── Сравнение способов измерения ────────────────────────────────────────

  /// Прогон сравнения: тот же конвейер кадров, OpenCV подключён тенью.
  ///
  /// Делается через `DetectionSession`, то есть через тот же код, который
  /// решает на телефоне. Только так числа и имеют смысл: рабочий способ меряет
  /// кадр и по нему же решает, а OpenCV вызывается самым последним шагом
  /// обработки, когда события уже приняты, — повлиять на решение ему нечем.
  ///
  /// План короткий и всегда один: фон даёт живому отсчёту набрать «ноль»,
  /// дальше по одному включению каждой лампы. Случайный режим и скорость
  /// мигания сюда не относятся — им проверяют тайминг, а не фотометрию.
  Future<void> _runShadowComparison() async {
    if (_shadowBusy) {
      return;
    }
    if (_scanning) {
      _stopScan();
    }
    setState(() {
      _shadowBusy = true;
      _message = 'Сравнение способов измерения…';
    });
    final OpenCvShadowRunner runner = _shadow ??= OpenCvShadowRunner(
      source: _source,
      // Тень меряет яркость, а не цвет: способ здесь назван прямо, чтобы
      // рабочий HSV по умолчанию (журнал 46) не добавлял в сравнение лишнего
      // отсчёта, который ничего не проверяет.
      config: const LampConfig(hsvReference: false),
      roi: simPictureRoi,
      setScene: (String scene) =>
          _source.setScene(SimScene.values.byName(scene)),
      onLine: (String line) => debugPrint('OPENCV $line'),
    );
    String path = '';
    try {
      runner.instrument.reset();
      final ShadowRunResult result = await runner.runPlan(
        const <ShadowPlanStep>[
          ShadowPlanStep('off', 24),
          ShadowPlanStep('white', 20),
          ShadowPlanStep('off', 24),
          ShadowPlanStep('red', 20),
          ShadowPlanStep('off', 12),
        ],
      );
      path = _writeReport(result.report);
      setState(() {
        _shadowLines = runner.lines;
        _shadowSummary =
            'кадров ${result.instrument.seen}, сбоев тени '
            '${result.instrument.failures}, событий у автомата '
            '${result.events} · файл $path';
      });
      debugPrint(
        'OPENCV готово: кадров=${result.instrument.seen} '
        'сбоев=${result.instrument.failures} событий=${result.events} '
        'файл=$path',
      );
    } on Object catch (e) {
      setState(() {
        _shadowSummary = 'прогон не получился: $e';
        _message = 'Сравнение не удалось: $e';
      });
      debugPrint('OPENCV сбой прогона: $e');
    } finally {
      if (mounted) {
        setState(() {
          _shadowBusy = false;
          if (_message == 'Сравнение способов измерения…') {
            _message = 'Сравнение готово.';
          }
        });
      }
      _source.setScene(SimScene.off);
    }
  }

  /// Текст сравнения обязан пережить прогон: у окна нет гарантированной
  /// консоли, а числа живут именно в этом тексте. Не удалось записать файл —
  /// это беда пути, а не прогона, поэтому наружу уходит строка с объяснением
  /// вместо исключения.
  String _writeReport(String report) {
    final String? configured = widget.openCvReportPath?.trim();
    final String path = configured == null || configured.isEmpty
        ? '${Directory.systemTemp.path}/lamp_opencv_compare.txt'
        : configured;
    try {
      File(path).writeAsStringSync(report);
      return path;
    } on Object catch (e) {
      debugPrint('OPENCV файл не записан: $e');
      return 'не записан ($e)';
    }
  }

  /// Тот же текст, что и в файле, но на экране: таблицы в 14 колонок в
  /// `debugPrint` не читаются, а спорить о числах нужно глазами.
  Future<void> _openShadowReport() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Сравнение способов измерения'),
          content: SizedBox(
            width: 900,
            height: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                _shadowLines.isEmpty
                    ? 'Прогон ещё не запускался.'
                    : _shadowLines.join('\n'),
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(_runShadowComparison());
              },
              child: const Text('Прогнать заново'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    _autoTimer?.cancel();
    _shadowTimer?.cancel();
    _shadow?.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Режим «только кадр»: управление и заголовок скрыты, картинка занимает
    // весь экран. Нужно для автотеста — так лампы крупные и никогда не уходят
    // за пределы видимости. Тап по экрану возвращает управление.
    if (_clean) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              onTap: () => setState(() => _clean = false),
              child: _source.buildPreview(),
            ),
            const Positioned(
              right: 10,
              bottom: 10,
              child: Icon(
                Icons.touch_app_outlined,
                size: 18,
                color: Colors.white24,
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тестовая панель'),
        actions: <Widget>[
          IconButton(
            onPressed: () => setState(() => _clean = true),
            icon: const Icon(Icons.fullscreen),
            tooltip: 'Только кадр (лампы на весь экран)',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _source.buildPreview(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              // Ряд кнопок 1: режим и скорость.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SegmentedButton<bool>(
                      segments: const <ButtonSegment<bool>>[
                        ButtonSegment<bool>(
                          value: false,
                          label: Text('Фиксировано'),
                          icon: Icon(Icons.repeat),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          label: Text('Случайно'),
                          icon: Icon(Icons.shuffle),
                        ),
                      ],
                      selected: <bool>{_random},
                      onSelectionChanged: (Set<bool> s) =>
                          setState(() => _random = s.first),
                    ),
                    const SizedBox(width: 12),
                    SegmentedButton<_Speed>(
                      segments: const <ButtonSegment<_Speed>>[
                        ButtonSegment<_Speed>(
                          value: _Speed.slow,
                          label: Text('Медленно'),
                        ),
                        ButtonSegment<_Speed>(
                          value: _Speed.medium,
                          label: Text('Средне'),
                        ),
                        ButtonSegment<_Speed>(
                          value: _Speed.fast,
                          label: Text('Быстро'),
                        ),
                      ],
                      selected: <_Speed>{_speed},
                      onSelectionChanged: (Set<_Speed> s) =>
                          setState(() => _speed = s.first),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              // Ряд кнопок 2: старт/стоп цикла, ручное удержание каждой лампы,
              // показ и сброс эталона. FittedBox, как в ряду режимов: окно
              // панели узкое (картинка 720×1280), а здесь уже пять элементов.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _scanning ? _stopScan : _startScan,
                      style: FilledButton.styleFrom(
                        backgroundColor: _scanning
                            ? Colors.redAccent
                            : Colors.teal,
                      ),
                      icon: Icon(_scanning ? Icons.stop : Icons.play_arrow),
                      label: Text(_scanning ? 'Стоп' : 'Старт'),
                    ),
                    const SizedBox(width: 4),
                    _manualChip(SimScene.white),
                    _manualChip(SimScene.red),
                    IconButton(
                      onPressed: _openViewSettings,
                      icon: const Icon(Icons.tune),
                      tooltip: 'Показ ламп и счёт по правилу детектора\n'
                          '${_viewSummary()}',
                      color: _isDefaultView ? Colors.grey : Colors.teal,
                    ),
                    IconButton(
                      onPressed: _resetFlashes,
                      icon: const Icon(Icons.restart_alt),
                      tooltip: 'Сбросить счётчики',
                      color: Colors.grey,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _counter('БЕЛАЯ', _flashWhite, _ruleWhite, Colors.white),
                        const SizedBox(width: 28),
                        _counter('КРАСНАЯ', _flashRed, _ruleRed, Colors.white70),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                    child: Text(
                      'вспышек · по правилу детектора '
                      '($_ruleFps к/с, кадр $_framePeriodMs мс, '
                      'on $_ruleOn / off $_ruleOff)',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              // Ряд кнопок 3: сравнение двух способов измерения на одних и тех
              // же кадрах. Оно ничего не решает и ничего не проверяет — оно
              // показывает числа, поэтому и кнопка отдельно от мигания.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _shadowBusy
                          ? null
                          : () => unawaited(_runShadowComparison()),
                      icon: const Icon(Icons.speed),
                      label: Text(
                        _shadowBusy ? 'Считаем…' : 'Сравнить способы',
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _shadowLines.isEmpty
                          ? null
                          : _openShadowReport,
                      child: const Text('Отчёт'),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                _shadowSummary,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                _message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Компактная кнопка ручного удержания одной лампы: «горит» = выбрано.
  ///
  /// Цвет нейтральный, как у счётчиков: подписи и кнопки попадают в кадр
  /// телефона, а красный рядом с рамками уже сбивал красную лампу. Различаются
  /// лампы словом, а не цветом.
  Widget _manualChip(SimScene scene) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Tooltip(
      message:
          '${_lampWord(scene)} лампа: включить и держать сколько нужно '
          '(калибровка «держим включённой»). Повторное нажатие гасит, вторая '
          'кнопка гасит эту — одновременно лампы не горят. Мигание при нажатии '
          'останавливается.',
      child: FilterChip(
        label: Text(_lampWord(scene), style: const TextStyle(fontSize: 12)),
        selected: _manualScene == scene,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        onSelected: (_) => _toggleManual(scene),
      ),
    ),
  );

  /// Два числа одной лампы: сколько вспышек было (`scenes`, эталон) и сколько
  /// насчитало бы правило детектора при идеальном кадре (`rule`). Равны —
  /// стимул в принципе считывается на этой частоте; правило меньше — часть
  /// вспышек теряет само правило (слишком короткое горение или пауза), и
  /// требовать от телефона большего бессмысленно. Больше эталона правило
  /// стать не может: сигнал здесь идеальный, ложных срабатываний неоткуда
  /// взяться.
  ///
  /// Цвета нейтральные (белый/серый): текст счётчиков попадает в кадр
  /// телефона, а красный рядом с рамками уже сбивал красную лампу.
  Widget _counter(String label, int scenes, int rule, Color color) => Tooltip(
    message:
        '$label: $scenes вспышек по сценам, $rule по правилу детектора '
        '(on $_ruleOn подряд кадров для включения, off $_ruleOff для гашения, '
        'кадр $_framePeriodMs мс).',
    child: Column(
      children: <Widget>[
        Text(
          '$scenes · $rule',
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    ),
  );
}

/// Скорость перелистывания сцен.
enum _Speed { slow, medium, fast }
