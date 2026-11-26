import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'widgets/event_log.dart';
import 'widgets/roi_editor.dart';

/// Демо детекции. На экране только главное: превью, «Пуск», строка «готов ли я
/// считать», а в режиме эталонов ещё и три кнопки калибровки. Рамки наводятся
/// пальцем.
///
/// В меню «⋮» ровно то, без чего прогона не сделать: переключатель способа
/// счёта, журнал событий, ошибки и сброс калибровки. Отладочные переключатели
/// (запись CSV и поток чисел) отсюда убраны и работают по умолчанию всегда:
/// разбираться с прогоном без чисел нечем, а в меню они мешали оператору у
/// лампы.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DetectionSession? _session;
  SqliteEventRepository? _repository;
  final List<HitEvent> _events = <HitEvent>[];
  final Map<String, String> _statuses = <String, String>{};
  final List<String> _errors = <String>[];
  String _message = 'Запуск…';
  StreamSubscription<HitEvent>? _hitsSub;
  StreamSubscription<String>? _errorsSub;
  bool _staleLogged = false;
  Timer? _logTimer;

  /// Способы счёта в меню. Отдельным списком, а не разбросанными `if`:
  /// оператор обязан видеть разом все варианты и какой из них включён, иначе
  /// переключатель превращается в угадывание.
  ///
  /// Живого (яркостного) способа здесь больше нет: на 16 записях стенда
  /// (108 событий) HSV даёт 54 ошибки против 73…85 у живого отсчёта
  /// (ЖУРНАЛ §11.12, `tools/hsv_decide.py matrix`). Остались два, и оба
  /// требуют те же три состояния калибровки: цветовому они дают имя вспышки
  /// (журнал 46), режиму эталонов — сами эталоны.
  /// Сам режим в перечислении остаётся — старые сохранённые настройки с ним
  /// встречаются, и [_menuModes] обязан показать включённый способ, даже когда
  /// он выпал из выбора: иначе прогон выглядит как будто выбран верхний пункт,
  /// а переключить его вслепую нельзя.
  static const List<({LampCountMode mode, String label, IconData icon})>
  _countModes = <({LampCountMode mode, String label, IconData icon})>[
    (
      mode: LampCountMode.hsv,
      label: 'по цвету HSV + калибровка',
      icon: Icons.palette_outlined,
    ),
    (
      mode: LampCountMode.etalon,
      label: 'по яркости (калибровка)',
      icon: Icons.straighten,
    ),
  ];

  /// Пункты меню способа счёта: выбор плюс текущий режим, если он в выбор не
  /// входит (переключённый на «живой» сохранённой старой настройкой).
  static List<({LampCountMode mode, String label, IconData icon})> _menuModes(
    LampCountMode current,
  ) => <({LampCountMode mode, String label, IconData icon})>[
    ..._countModes,
    if (current == LampCountMode.live)
      (
        mode: LampCountMode.live,
        label: 'живой (без калибровки)',
        icon: Icons.wifi_tethering,
      ),
  ];

  /// Сколько ждём подъёма камеры. Больше — и первый запуск выглядит зависшим:
  /// плагин `camera` на части устройств не отвечает вовсе, а оператор обязан
  /// видеть причину, а не крутящееся «Запуск…».
  static const Duration _bringUpTimeout = Duration(seconds: 25);

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final Directory directory = await lampDataDirectory();
      final SqliteEventRepository repository = SqliteEventRepository(
        fileName: SqliteEventRepository.defaultFileName,
        directory: directory.path,
      );
      _repository = repository;
      final SettingsStore settings = await SettingsStore.open();
      final MockHitEventSender sender = MockHitEventSender();
      final CameraFrameSource source = CameraFrameSource();
      final DetectionSession session = DetectionSession(
        source: source,
        repository: repository,
        sender: sender,
        settings: settings,
        csvRecorder: FeatureCsvRecorder(directory: directory),
      );
      await session.loadSettings().timeout(_bringUpTimeout);
      session.addListener(_onSessionChanged);
      _hitsSub = session.hits.listen(_onHit);
      _errorsSub = session.errors.listen(
        (String message) => setState(() => _errors.insert(0, message)),
      );
      setState(() {
        _session = session;
        _message = 'Наведи рамки';
      });
      // Поток LAMPDBG в logcat (тег LAMPDBG) и покадровая CSV включены всегда,
      // без переключателей: logcat переживает только хвост прогона, а сам прогон
      // обычно делают без кабеля.
      _logTimer?.cancel();
      _logTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _dumpNumbers(),
      );
      await session.setRecordingCsv(true);
      // Камера показывается сразу, без нажатия «Пуск».
      await _startSession(session, firstStep: 'Наведи рамки');
    } on Object catch (e) {
      setState(() => _message = 'Сбой: ${_short(e)}');
    }
  }

  /// Пускает сессию и всегда возвращает управление экрану: зависший насовсем
  /// «Запуск…» хуже, чем честное «камера молчит».
  Future<void> _startSession(
    DetectionSession session, {
    String firstStep = 'Пуск',
  }) async {
    try {
      await session.start().timeout(_bringUpTimeout);
      if (!mounted) {
        return;
      }
      setState(() => _message = _nextStepMessage(session));
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(
        () => _message =
            'Камера молчит ${_bringUpTimeout.inSeconds} с: дай разрешение на '
            'камеру и жми «$firstStep»',
      );
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _message = 'Камера: ${_short(e)}');
    }
  }

  /// Внизу экрана — только следующее действие, одной строкой.
  static String _nextStepMessage(DetectionSession session) =>
      session.canEvaluate ? '' : 'Жми «1 ФОН»';

  /// Подробности ошибки уже в «Ошибках» и в логе, здесь — первая строка.
  static String _short(Object e) {
    final String s = e.toString();
    final int nl = s.indexOf('\n');
    final String one = nl < 0 ? s : s.substring(0, nl);
    return one.length <= 40 ? one : '${one.substring(0, 40)}…';
  }

  void _onSessionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onHit(HitEvent event) {
    setState(() {
      _events.insert(0, event);
      _message =
          '${event.lampId == HitEvent.whiteLampId ? 'БЕЛАЯ' : 'КРАСНАЯ'}'
          ' #${event.sequenceNumber}';
    });
    unawaited(_refreshStatuses());
  }

  /// Статусы доставки читаются из SQLite — они и есть источник правды.
  Future<void> _refreshStatuses() async {
    final SqliteEventRepository? repository = _repository;
    final DetectionSession? session = _session;
    if (repository == null || session == null) {
      return;
    }
    final List<StoredEvent> stored = await repository.eventsWithStatus(
      session.sessionId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _statuses.clear();
      for (final StoredEvent item in stored) {
        _statuses[item.event.eventId] =
            item.status.name + (item.attempts > 0 ? ' x${item.attempts}' : '');
      }
    });
  }

  @override
  void dispose() {
    _logTimer?.cancel();
    unawaited(_hitsSub?.cancel());
    unawaited(_errorsSub?.cancel());
    _session?.removeListener(_onSessionChanged);
    unawaited(_session?.dispose());
    super.dispose();
  }

  Future<void> _toggleRun() async {
    final DetectionSession session = _session!;
    if (session.isRunning) {
      await session.stop();
      setState(() => _message = 'Остановлено');
      return;
    }
    setState(() => _message = 'Запуск…');
    await _startSession(session);
  }

  /// Строка LAMPROI в logcat: куда рамки переходят после наложения поворота и
  /// зеркала сенсора. Когда события почему-то считаются одной лампой, первое,
  /// что стоит посмотреть, — левая ли рамка кадра оказалась левой на экране.
  /// Ничего не меняет: ни ROI, ни калибровку.
  void _logRoiGeometry(DetectionSession session) {
    final FrameMapping m = session.source.mapping;
    final RoiLayout roi = session.roi;
    debugPrint(
      'LAMPROI turns=${m.quarterTurns} mirror=${m.mirrorHorizontal} '
      'preview=${session.source.previewSize} '
      'W L=${roi.white.left.toStringAsFixed(3)} T=${roi.white.top.toStringAsFixed(3)} | '
      'R L=${roi.red.left.toStringAsFixed(3)} T=${roi.red.top.toStringAsFixed(3)} | '
      'frameW L=${m.toFrameRoi(roi.white).left.toStringAsFixed(3)} '
      'T=${m.toFrameRoi(roi.white).top.toStringAsFixed(3)} | '
      'frameR L=${m.toFrameRoi(roi.red).left.toStringAsFixed(3)} '
      'T=${m.toFrameRoi(roi.red).top.toStringAsFixed(3)}',
    );
  }

  /// Одно нажатие — один снятый шаг. Автоматикой тут ничего не управляется:
  /// человек сам держит нужную лампу и сам жмёт её кнопку, когда сцена готова.
  /// Что делать и сколько это держать — говорит панель кнопок и счётчик над
  /// камерой; длинных инструкций намеренно нет, у лампы их читают одной рукой.
  Future<void> _calibrateStep(CalibrationStep step) async {
    final DetectionSession session = _session!;
    debugPrint('LAMPROI step ${step.csvTag} start');
    _logRoiGeometry(session);
    setState(() => _message = 'Набор «${step.label}»…');
    try {
      final CalibrationReport report = await session.calibrateStep(step);
      debugPrint('LAMPROI step ${step.csvTag} done: ${report.describe()}');
      setState(() => _message = report.describe());
    } on CalibrationException catch (e) {
      // Шаг шумел или лампа не увидна: снимается ровно он, остальные остаются.
      setState(
        () => _message =
            '«${e.step?.key ?? step.key}» не принят — жми его кнопку',
      );
    } on StateError catch (e) {
      // Ответ на нажатие не той кнопки: набор прерван другой, или фон ещё не
      // снят. Аварии нет, поэтому и слова «Сбой» тут быть не должно.
      setState(() => _message = _short(e));
    } on Object catch (e) {
      setState(() => _message = 'Сбой: ${_short(e)}');
    }
  }

  /// Забыть калибровку целиком: базу, собранные состояния и «пол» живого
  /// отсчёта. Счётчики ударов остаются — для них есть отдельный ⟳.
  ///
  /// Что делать дальше говорит полоса готовности, а не эта строка: в режиме
  /// эталонов там «нет калибровки — жми 1 ФОН», а в живом отсчёте калибровка не
  /// нужна вовсе и остаётся только дождаться нового «пола».
  void _resetCalibration() {
    final DetectionSession session = _session!;
    session.resetCalibration();
    setState(() => _message = 'Калибровка сброшена. ${session.readiness.why}');
  }

  /// Что считает прогон — метка в каждой строке лога.
  String get _modeTag {
    final DetectionSession? s = _session;
    if (s == null) {
      return 'ref=?';
    }
    return 'ref=${s.config.countMode.name}';
  }

  /// Компактная строка чисел прогона в logcat (тег LAMPDBG), примерно 5 раз/с.
  ///
  /// Живой отсчёт: `wf`/`rf` — доли в колпаке, `wr`/`rr` — в ореоле, `aW`/`aR` —
  /// подъём над «полом» (в тех же единицах, что и порог `onW`/`onR`); «пол»
  /// восстанавливается как `доля − подъём`. `nW`/`nR` — тот же подъём без
  /// общего для обеих рамок света: по нему решается о ВЫКЛЮЧЕНИИ, и именно по
  /// нему видно, залип ли канал из-за соседа.
  ///
  /// Режим эталонов: `bg` — сохранённый фон, `aW`/`aR` — амплитуды в долях
  /// измеренного отклика, `res` — невязка.
  void _dumpNumbers() {
    final DetectionSession? s = _session;
    final LampFrame? f = s?.lastFeatures;
    if (s == null || f == null) {
      return;
    }
    // После «Стоп» кадры не приходят, а lastFeatures остаётся — без этого
    // стража лог 5 раз в секунду враньём показывает один и тот же старый кадр.
    if (!s.isRunning) {
      if (!_staleLogged) {
        _staleLogged = true;
        debugPrint('LAMPDBG live — камера остановлена, числа ниже не свежие');
      }
      return;
    }
    _staleLogged = false;
    final LampEvaluation? e = s.lastEvaluation;
    // Прочерк вместо 0.000 у ореола: «кольцо есть, но тёмное» и «кольцо
    // отброшено» — разные болезни. Первая — рамка не на лампе, вторая — ореол
    // съеден чужой рамкой или краем кадра и решать по нему нельзя.
    final FrameFeatures? whiteRing = f.whiteRing;
    final FrameFeatures? redRing = f.redRing;
    if (s.config.countMode == LampCountMode.hsv) {
      // HSV-прогон: `cf`/`wr` — доли «белых» и «красных» пикселей в колпаке;
      // решают не они сами, а их подъём `aW`/`aR` над «полом». `p90` — яркость
      // зоны (по ней видно стоп на потолке сенсора), `onW`/`onR` — порог этого
      // же прогона. Ореолы не печатаются: модель решает по одной зоне.
      // В режиме выученного правила (`sign=…` в хвосте строки) `aW` и `aR` —
      // ОДНО число, подъём общего канала: событие ищется без догадки о том,
      // какой канал «свой», а лампу называет `имя=`.
      debugPrint(
        'LAMPDBG hsv $_modeTag '
        'W cf=${f.white.coolFrac.toStringAsFixed(3)} '
        'wr=${f.white.warmFrac.toStringAsFixed(3)} '
        '| R cf=${f.red.coolFrac.toStringAsFixed(3)} '
        'wr=${f.red.warmFrac.toStringAsFixed(3)} '
        '| aW=${(e?.whiteAmplitude ?? 0).toStringAsFixed(3)} '
        'aR=${(e?.redAmplitude ?? 0).toStringAsFixed(3)} '
        'onW=${(s.whiteOnLevel ?? 0).toStringAsFixed(3)} '
        'onR=${(s.redOnLevel ?? 0).toStringAsFixed(3)} '
        '| lit W=${e?.whiteLit ?? false} R=${e?.redLit ?? false} '
        'amb=${s.diagnostics.snapshot.ambiguousFrames} '
        'both=${s.doubleBasketFrames} '
        '| p90 w=${f.white.p90Luma.toStringAsFixed(0)} '
        'r=${f.red.p90Luma.toStringAsFixed(0)} '
        'dark W=${e?.whiteDarkMs ?? 0}ms R=${e?.redDarkMs ?? 0}ms '
        'exp=${s.exposureLocked ? "lock" : "auto"} '
        '| hits W=${s.whiteHits} R=${s.redHits} ${s.liveDebugTag}',
      );
      return;
    }
    if (s.config.liveReference) {
      debugPrint(
        'LAMPDBG live $_modeTag '
        'W wf=${f.white.whiteFrac.toStringAsFixed(3)} '
        'wr=${whiteRing == null ? "-" : whiteRing.whiteFrac.toStringAsFixed(3)} '
        '| R rf=${f.red.redFrac.toStringAsFixed(3)} '
        'rr=${redRing == null ? "-" : redRing.redFrac.toStringAsFixed(3)} '
        '| aW=${(e?.whiteAmplitude ?? 0).toStringAsFixed(3)} '
        'aR=${(e?.redAmplitude ?? 0).toStringAsFixed(3)} '
        'nW=${(e?.whiteNet ?? 0).toStringAsFixed(3)} '
        'nR=${(e?.redNet ?? 0).toStringAsFixed(3)} '
        'onW=${(s.whiteOnLevel ?? 0).toStringAsFixed(3)} '
        'onR=${(s.redOnLevel ?? 0).toStringAsFixed(3)} '
        '| lit W=${e?.whiteLit ?? false} R=${e?.redLit ?? false} '
        'amb=${s.diagnostics.snapshot.ambiguousFrames} '
        'both=${s.doubleBasketFrames} '
        // Яркость обеих рамок и состояние лока: без этого не отличить вспышку
        // лампы от того, как автоэкспозиция пересчитала свет, и не увидеть
        // пересвет (Y упирается в 255).
        '| Y w=${f.white.meanY.toStringAsFixed(0)} '
        'r=${f.red.meanY.toStringAsFixed(0)} '
        // p90 — та величина, по которой решение принимает (`wf`/`rf` напечатаны
        // для справки: цвет измеряется, но ни на одно решение не влияет), а
        // `dark` — сколько длится текущий провал: по нему видно, ЗАЧЕМ канал
        // не отпускает («горит» навечно = провал не подтверждён).
        '| p90 w=${f.white.p90Luma.toStringAsFixed(0)} '
        'wr=${whiteRing == null ? "-" : whiteRing.p90Luma.toStringAsFixed(0)} '
        'r=${f.red.p90Luma.toStringAsFixed(0)} '
        'rr=${redRing == null ? "-" : redRing.p90Luma.toStringAsFixed(0)} '
        'dark W=${e?.whiteDarkMs ?? 0}ms R=${e?.redDarkMs ?? 0}ms '
        'exp=${s.exposureLocked ? "lock" : "auto"} '
        '| hits W=${s.whiteHits} R=${s.redHits} ${s.liveDebugTag}',
      );
      return;
    }
    final CalibrationState? bg = s.baseline?.background;
    debugPrint(
      'LAMPDBG etalon $_modeTag '
      'W wf=${f.white.whiteFrac.toStringAsFixed(3)} '
      'rf=${f.white.redFrac.toStringAsFixed(3)} '
      'bg=${(bg?.white.whiteFrac ?? 0).toStringAsFixed(3)} '
      '| R wf=${f.red.whiteFrac.toStringAsFixed(3)} '
      'rf=${f.red.redFrac.toStringAsFixed(3)} '
      'bg=${(bg?.red.redFrac ?? 0).toStringAsFixed(3)} '
      '| aW=${(e?.whiteAmplitude ?? 0).toStringAsFixed(2)} '
      'aR=${(e?.redAmplitude ?? 0).toStringAsFixed(2)} '
      'onW=${(s.whiteOnLevel ?? 0).toStringAsFixed(2)} '
      'onR=${(s.redOnLevel ?? 0).toStringAsFixed(2)} '
      'res=${(e?.residual ?? 0).toStringAsFixed(3)} '
      '| lit W=${e?.whiteLit ?? false} R=${e?.redLit ?? false} '
      '| unexp=${s.diagnostics.snapshot.unexplainedFrames} '
      'amb=${s.diagnostics.snapshot.ambiguousFrames} '
      'both=${s.doubleBasketFrames} '
      '| hits W=${s.whiteHits} R=${s.redHits}',
    );
  }

  Future<void> _sheet(String title, Widget child) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppBar(title: Text(title), automaticallyImplyLeading: false),
          Flexible(child: child),
        ],
      ),
    ),
  );

  static String _shortSession(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  @override
  Widget build(BuildContext context) {
    final DetectionSession? session = _session;
    // Шапка стоит 56 пунктов высоты, а величину кадра в ландшафте задаёт
    // именно высота: кадр 4:3 упирается в неё, ширина остаётся запасом. И по
    // этой же высоте считаются рамки. Поэтому в ландшафте шапки нет, а её меню
    // переезжает в правую панель — плюс 56 пунктов к картинке.
    final bool landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final Widget menu = switch (session) {
      final DetectionSession s => PopupMenuButton<String>(
        onSelected: (String id) => _onMenu(id, s),
        // Компактно и без внутренних отступов: в правой панели ландшафта
        // кнопка по умолчанию (48×48 + padding) залезала на «Пуск».
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          for (final ({LampCountMode mode, String label, IconData icon}) option
              in _menuModes(s.config.countMode))
            PopupMenuItem<String>(
              value: 'mode:${option.mode.name}',
              child: Row(
                children: <Widget>[
                  Icon(
                    option.icon,
                    size: 18,
                    color: s.config.countMode == option.mode
                        ? Colors.tealAccent
                        : Colors.white38,
                  ),
                  const SizedBox(width: 10),
                  // Flexible, а не голый Text: длина пункта («Счёт: по
                  // цвету HSV (без калибровки)») уже ширины всплывающего
                  // меню на узком телефоне, и без ограничения строка
                  // залезала за край (Right overflowed by 41 pixels).
                  Flexible(
                    child: Text(
                      (s.config.countMode == option.mode
                              ? '▪ Счёт: '
                              : '   Счёт: ') +
                          option.label,
                      style: const TextStyle(fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (s.config.countMode != LampCountMode.etalon)
            PopupMenuItem<String>(
              value: 'sens',
              child: Row(
                children: <Widget>[
                  const Icon(Icons.speed, size: 18, color: Colors.tealAccent),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Порог: ${s.liveSensitivityLabel}',
                      style: const TextStyle(fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          const PopupMenuItem<String>(
            value: 'calreset',
            child: Text('Сброс калибровки'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'log',
            child: Text('Журнал событий'),
          ),
          const PopupMenuItem<String>(value: 'errors', child: Text('Ошибки')),
        ],
      ),
      null => const SizedBox.shrink(),
    };
    return Scaffold(
      appBar: landscape
          ? null
          : AppBar(
              title: Text(
                session == null
                    ? 'Lamp detection'
                    : 'Lamp detection · ${_shortSession(session.sessionId)}',
              ),
              actions: <Widget>[menu],
            ),
      body: session == null
          ? Center(child: Text(_message))
          : SafeArea(
              child: OrientationBuilder(
                builder: (BuildContext context, Orientation orientation) {
                  // Колонка «панель → кадр → счётчики» в ландшафте оставляет
                  // от экрана полосу: лампы в ней мельчают, и рамки правится
                  // вслепую. Здесь панель уезжает на правый край, а кадр берёт
                  // всю высоту — на 18:9 он становится крупнее примерно вдвое.
                  final bool landscape = orientation == Orientation.landscape;
                  final Widget controls = _PrimaryControls(
                    session: session,
                    onRun: _toggleRun,
                    dense: orientation == Orientation.landscape,
                  );
                  // Кнопки трёх состояний нужны ОБА калибровочных способа,
                  // включая цветовой. Слово заказчика 25.11.2026, второе за
                  // тот же день: «совмести наработку hsv и калибровку всё в
                  // одно, будем только с калибровкой работать» — прежний
                  // запрет («если счёт по цвету — три кнопки убирать») он
                  // отменяет, и отменять его было чем: `HsvSignature.learn`
                  // учится ровно по этим трём состояниям, и без кнопок
                  // границу не выучить никогда (`sign=нет`), а по замерам на
                  // ручной разметке координат это 100 ошибок вместо 60
                  // (`tools/hsv_decide.py sign 0.06 3.0 auto manual`, журнал
                  // 46). Живому отсчёту кнопки не нужны — там калибровка ни на
                  // что не влияет, и способ в меню больше не предлагается.
                  final Widget steps =
                      session.config.countMode == LampCountMode.live
                      ? const SizedBox.shrink()
                      : _CalibrationSteps(
                          session: session,
                          onStep: _calibrateStep,
                          vertical: landscape,
                        );
                  final Widget stage = Padding(
                    padding: EdgeInsets.all(landscape ? 0 : 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _AspectStage(
                        previewSize: session.source.previewSize,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            session.source.buildPreview(),
                            RoiEditor(
                              layout: session.roi,
                              onChanged: (RoiLayout layout) =>
                                  session.updateRoi(layout),
                              onCommit: () {
                                unawaited(session.saveRoi());
                                setState(() => _message = 'ROI сохранены');
                              },
                            ),
                            // Счётчик набора поверх камеры. Он ничего не
                            // перехватывает: панель рисует только текст, а
                            // текст и ColoredBox под тапом подписок на жесты
                            // не имеют — рамки правятся прямо во время набора.
                            // Кнопки шагов живут над превью, в _CalibrationSteps.
                            _CollectionOverlay(session: session),
                          ],
                        ),
                      ),
                    ),
                  );
                  final Widget status = _StatusRow(
                    session: session,
                    onReset: () {
                      session.resetCounters();
                      setState(() => _message = 'Сброшено');
                    },
                    dense: landscape,
                  );
                  final Widget note = Padding(
                    padding: EdgeInsets.fromLTRB(
                      landscape ? 4 : 16,
                      4,
                      landscape ? 4 : 16,
                      landscape ? 2 : 12,
                    ),
                    child: Text(
                      _message,
                      textAlign: TextAlign.center,
                      maxLines: landscape ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: landscape ? 10 : 12,
                        color: Colors.grey,
                      ),
                    ),
                  );
                  if (!landscape) {
                    return Column(
                      children: <Widget>[
                        controls,
                        steps,
                        Expanded(child: stage),
                        status,
                        note,
                      ],
                    );
                  }
                  // Правая панель — ровно под кнопку, три шага калибровки и
                  // счётчики; всё, что можно отдать картинке, отдано ей.
                  return Row(
                    children: <Widget>[
                      Expanded(child: stage),
                      SizedBox(
                        width: 156,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Row(children: <Widget>[controls, menu]),
                            steps,
                            Expanded(child: status),
                            note,
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
    );
  }

  Future<void> _onMenu(String id, DetectionSession session) async {
    switch (id) {
      case String() when id.startsWith('mode:'):
        // Пункт меню назван способом счёта: выбирается он прямо по имени, а не
        // угадывается по прежнему состоянию — «рубильник» из двух положений
        // всегда оставлял вопрос, что было включено. Ищется по перечислению, а
        // не по списку меню: включённый способ обязан переключаться, даже
        // когда самого пункта в меню уже нет.
        final String picked = id.substring('mode:'.length);
        for (final LampCountMode mode in LampCountMode.values) {
          if (mode.name == picked) {
            await session.setCountMode(mode);
            break;
          }
        }
        setState(() => _message = session.readiness.why);
      case 'calreset':
        _resetCalibration();
      case 'sens':
        // Три пресета порога по кругу: меняется одно число, множитель σ.
        await session.cycleLiveSensitivity();
        setState(() => _message = 'Порог: ${session.liveSensitivityLabel}');
      case 'log':
        await _sheet(
          'Журнал событий',
          EventLog(events: _events, statuses: _statuses),
        );
      case 'errors':
        await _sheet(
          'Ошибки',
          ListView(
            padding: const EdgeInsets.all(12),
            children: _errors
                .map(
                  (String e) => Text(e, style: const TextStyle(fontSize: 12)),
                )
                .toList(),
          ),
        );
    }
  }
}

class _PrimaryControls extends StatelessWidget {
  const _PrimaryControls({
    required this.session,
    required this.onRun,
    this.dense = false,
  });

  final DetectionSession session;
  final VoidCallback onRun;

  /// Кнопка в правой панели ландшафта: рядом с ней ещё меню, поэтому отступы
  /// и шрифт срезаны — «Пуск» обязан влезать в 90 пунктов.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final LampStatus status = session.status;
    if (dense) {
      // В правой панели ландшафта подпись только мешала: «Стоп» с текстом
      // переносилось в столбик и лезло на меню. Состояние видно по цвету и
      // значку (красный с квадратом = идёт набор, бирюзовый с треугольником =
      // стоит), имя кнопки — в подсказке.
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 2, 0),
        child: FilledButton(
          onPressed: onRun,
          style: FilledButton.styleFrom(
            backgroundColor: status.running ? Colors.redAccent : Colors.teal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(56, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Icon(status.running ? Icons.stop : Icons.play_arrow, size: 22),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FilledButton.icon(
              onPressed: onRun,
              style: FilledButton.styleFrom(
                backgroundColor: status.running
                    ? Colors.redAccent
                    : Colors.teal,
              ),
              icon: Icon(status.running ? Icons.stop : Icons.play_arrow),
              label: Text(status.running ? 'Стоп' : 'Пуск'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Три кнопки калибровки — по одной на шаг: «1 ФОН», «2 БЕЛАЯ», «3 КРАСНАЯ».
///
/// Никакой очереди, никаких таймеров и никакого «набирай сейчас»: кнопка
/// запускает набор ровно своего шага в тот момент, когда человек видит в
/// кадровом окне нужное состояние сцены. Порядок нажатий не важен — снять
/// можно и один шаг, остальные подставятся из рабочей калибровки.
///
/// Кнопка всегда показывает, в каком состоянии её шаг: ✓ — снят, N/M — сейчас
/// набирается, ⚠ — этот шаг был отвергнут (причина в строке под кнопками), кружок
/// — ещё не снят. Подсказка «что делать» остаётся на экране всё время, а не
/// только во время прогона: у лампы читают именно её.
class _CalibrationSteps extends StatelessWidget {
  const _CalibrationSteps({
    required this.session,
    required this.onStep,
    this.vertical = false,
  });

  final DetectionSession session;
  final Future<void> Function(CalibrationStep step) onStep;

  /// Кнопки в столбик — для правой панели ландшафта: в ряд шириной 184 они
  /// не читаются.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final LampStatus s = session.status;
    final List<Widget> buttons = CalibrationStep.values
        .map((CalibrationStep step) => _button(step, s))
        .toList(growable: false);
    return Padding(
      padding: vertical
          ? const EdgeInsets.fromLTRB(6, 0, 6, 4)
          : const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        children: <Widget>[
          vertical
              ? Column(children: <Widget>[for (final Widget b in buttons) b])
              : Row(
                  children: <Widget>[
                    for (final Widget b in buttons) Expanded(child: b),
                  ],
                ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.calibrationError.isNotEmpty
                  ? s.calibrationError
                  : s.calibrationHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: vertical ? 11 : 13,
                fontWeight: FontWeight.bold,
                color: s.calibrationError.isNotEmpty
                    ? Colors.redAccent
                    : Colors.tealAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _button(CalibrationStep step, LampStatus s) {
    final CalibrationProgress p = s.calibration;
    final bool collecting = s.calibrating && p.step == step;
    // Успешная калибровка состояния стирает (они превратились в модель), поэтому
    // «всё снято» выглядит как рабочий baseline без недобранных шагов.
    final bool allShot = s.isCalibrated && s.completedSteps.isEmpty;
    final bool shot = allShot || s.completedSteps.contains(step);
    // Отвергнутый шаг сессия оставляет тем, на котором всё и сломалось:
    // переснимать нужно ровно его, и кнопка должна об этом сказать.
    final bool refused =
        !s.calibrating && s.calibrationError.isNotEmpty && p.step == step;
    final (IconData, Color) mark = collecting
        ? (Icons.timelapse, Colors.tealAccent)
        : refused
        ? (Icons.error_outline, Colors.redAccent)
        : shot
        ? (Icons.check_circle, Colors.teal)
        : (Icons.radio_button_unchecked, Colors.white54);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: FilledButton.tonalIcon(
        // Повторное нажатие по набираемой кнопке ничего не перезапускает, а
        // другая кнопка посреди набора просто переключает шаг — поэтому блокировать
        // их во время набора незачем.
        onPressed: s.running && !collecting ? () => onStep(step) : null,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(mark.$1, color: mark.$2, size: 18),
        label: Text(
          collecting ? '${p.collected}/${p.needed}' : step.key,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}

/// Идущий набор шага — крупно поверх превью: что держать и сколько кадров
/// осталось.
///
/// Экран обязан отвечать сам: у лампы человек держит её рукой и не читает
/// абзацы. Здесь только счётчик набора — запускается шаг всегда его собственной
/// кнопкой выше, поэтому никакого «набирай сейчас», никаких фаз ожидания и
/// никакого обратного отсчёта: время включения лампы предсказать нельзя, а
/// прошлый дедлайн молча запускал набор, когда лампу так и не включили.
/// Виджет перерисовывает себя сам по wall-clock, не дожидаясь, пока сессия
/// о чём-то сообщит: во время стабилизации кадры в эталон не идут, и счётчик
/// стоял бы мёртво.
class _CollectionOverlay extends StatefulWidget {
  const _CollectionOverlay({required this.session});

  final DetectionSession session;

  @override
  State<_CollectionOverlay> createState() => _CollectionOverlayState();
}

class _CollectionOverlayState extends State<_CollectionOverlay> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _active) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  bool get _active => widget.session.status.calibrating;

  @override
  Widget build(BuildContext context) {
    final LampStatus s = widget.session.status;
    if (!_active) {
      return const SizedBox.shrink();
    }
    final CalibrationStep step = s.calibration.step;
    final String what = switch (step) {
      CalibrationStep.background => 'ДЕРЖИ ОБЕ ПОГАШЕНЫ',
      CalibrationStep.whiteOn => 'ДЕРЖИ БЕЛУЮ',
      CalibrationStep.redOn => 'ДЕРЖИ КРАСНУЮ · БЕЛУЮ ПОГАСИ',
    };
    final String big;
    final String small;
    if (s.settling) {
      // Первые кадры шага отбрасываются (лампа и автоэкспозиция после
      // перелоксировки сходятся), поэтому счётчик кадров стоит.
      big = '…';
      small = 'стабилизация · ${s.phaseSeconds} с';
    } else {
      final CalibrationProgress c = s.calibration;
      final double fps = widget.session.diagnostics.snapshot.analysisFps;
      big = '${c.remaining}';
      small = fps > 0
          ? 'кадров · ~${(c.remaining / fps).toStringAsFixed(1)} с'
          : 'кадров';
    }
    // Обе строки — про качество света, без них калибровка проходит «успешно» и
    // молча оказывается слепой.
    final String warning = !s.exposureLocked
        ? 'Экспозиция не заперта: камера пересчитывает свет, цифры плывут'
        : s.overexposed
        ? 'Пересвет: в рамке нет ни цвета, ни яркости'
        : '';
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: ColoredBox(
          color: const Color(0xC0000000),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '${step.number}/3 · $what',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    big,
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.bold,
                      color: Colors.tealAccent,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    small,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                  if (warning.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        warning,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.amberAccent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.session,
    required this.onReset,
    this.dense = false,
  });

  final DetectionSession session;
  final VoidCallback onReset;

  /// Плотная раскладка для ландшафта: счётчики встают в правую панель, где
  /// цифра в 40 пунктов заняла бы треть высоты.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final LampStatus status = session.status;
    final Widget white = _counter(
      'БЕЛАЯ',
      status.whiteHits,
      status.whiteLit,
      Colors.white,
    );
    final Widget red = _counter(
      'КРАСНАЯ',
      status.redHits,
      status.redLit,
      Colors.redAccent,
    );
    final Widget reset = IconButton(
      onPressed: onReset,
      icon: Icon(Icons.restart_alt, size: dense ? 22 : 24),
      tooltip: 'Сбросить счётчики',
      color: Colors.grey,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 0 : 4),
      child: dense
          ? Center(
              // scaleDown, а не голая колонка: когда в панели ещё и шаги
              // калибровки, места остаётся меньше, чем просят два счётчика с
              // подписями, — и вместо переполнения цифры чуть уменьшаются.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[white, reset, red],
                ),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[white, reset, red],
            ),
    );
  }

  Widget _counter(String label, int value, bool lit, Color color) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(
        '$value',
        style: TextStyle(
          fontSize: dense ? 20 : 32,
          fontWeight: FontWeight.bold,
          color: lit ? color : Colors.grey,
        ),
      ),
      Text(
        label,
        style: TextStyle(fontSize: dense ? 10 : 12, color: Colors.grey),
      ),
    ],
  );
}

/// Держит превью и ROI в реальном соотношении сторон кадра. Без этого
/// `CameraPreview` внутри `StackFit.expand` растягивается на всю область, и
/// ROI настраиваются по искажённой картинке.
class _AspectStage extends StatelessWidget {
  const _AspectStage({required this.previewSize, required this.child});

  final Size? previewSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Size? size = previewSize;
    if (size == null || size.width <= 0 || size.height <= 0) {
      return child;
    }
    // previewSize камеры всегда «ландшафтный» (w > h); в портрете меняем стороны.
    final bool portrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final double longSide = size.width >= size.height
        ? size.width
        : size.height;
    final double shortSide = size.width >= size.height
        ? size.height
        : size.width;
    final double aspect = portrait
        ? shortSide / longSide
        : longSide / shortSide;
    return Center(
      child: AspectRatio(aspectRatio: aspect, child: child),
    );
  }
}
