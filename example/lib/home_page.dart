import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'opencv_features.dart';
import 'opencv_shadow.dart';
import 'widgets/event_log.dart';
import 'widgets/roi_editor.dart';

/// Демо детекции. На экране только главное: превью, «Пуск», три кнопки
/// калибровки и строка «готов ли я считать». Рамки наводятся пальцем.
///
/// В меню «⋮» ровно то, без чего прогона не сделать: способ решения, журнал
/// событий, ошибки и сброс калибровки. Отладочные переключатели (запись CSV и
/// поток чисел) отсюда убраны и работают по умолчанию всегда: разбираться с
/// прогоном без чисел нечем, а в меню они мешали оператору у лампы.
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

  /// Теневой измеритель OpenCV: пока не выключен, каждый кадр после решения
  /// основного конвейера мерится вторым способом. Решений он не принимает —
  /// подключён как `ShadowProbe` и вызывается после отправки событий.
  OpenCvShadowInstrument? _shadow;

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
      session.canEvaluate ? 'Считаю' : 'Жми «1 ФОН»';

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
      _message = '${event.lampId == HitEvent.whiteLampId ? 'БЕЛАЯ' : 'КРАСНАЯ'}'
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
    final List<StoredEvent> stored = await repository.eventsWithStatus(session.sessionId);
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
    _session?.shadowProbe = null;
    _shadow?.dispose();
    _shadow = null;
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

  /// Вернуть набор к кнопке «1 ФОН», ничего не сохраняя.
  void _resetCalibration() {
    _session!.resetCalibration();
    setState(() => _message = 'Сброшено. Жми «1 ФОН»');
  }

  /// Включает и выключает теневой измеритель OpenCV.
  ///
  /// Включение ставит `session.shadowProbe`: каждый кадр после решения
  /// основного конвейера мерится вторым способом, но ни пороги, ни событие
  /// тень не трогает — вызов идёт после отправки, ошибка гасится сама.
  /// Выключение печатает накопленное: таблицу «рабочий | OpenCV», сводку
  /// расхождений и путь к файлу отчёта.
  Future<void> _toggleShadow(DetectionSession session) async {
    final OpenCvShadowInstrument? active = _shadow;
    if (active != null) {
      session.shadowProbe = null;
      final String report = active.report();
      final int seen = active.seen;
      final int failures = active.failures;
      active.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _shadow = null;
        _message = 'OpenCV: $seen кадров, сбоев $failures';
      });
      final String path = await _writeShadowReport(report);
      debugPrint('OPENCV отчёт: $path');
      // Сводка — в logcat целиком: по ней видно, сходятся ли способы,
      // не дёргая pull файла. Таблицу кадров в лог не дублируем.
      for (final String line in report.split('\n')) {
        if (line.startsWith('сводка') ||
            line.startsWith('  ') ||
            line.startsWith('центр') ||
            line.startsWith('яркость')) {
          debugPrint('OPENCV $line');
        }
      }
      if (mounted) {
        await _showShadowReport(report, path);
      }
      return;
    }
    final OpenCvShadowInstrument instrument = OpenCvShadowInstrument(
      extractor: OpenCvFeatureExtractor(config: session.config),
      workingExtractor: FeatureExtractor(session.config),
      maxPairs: 400,
    );
    session.shadowProbe = instrument.observe;
    if (!mounted) {
      return;
    }
    setState(() {
      _shadow = instrument;
      _message = 'OpenCV считаю… прогон off/white/off/red, жми ещё раз';
    });
  }

  /// Отчёт живёт вне памяти приложения: числа нужны и после закрытия экрана,
  /// а файл проще всего снять с устройства (run-as) или через лог.
  Future<String> _writeShadowReport(String report) async {
    try {
      final Directory directory = await lampDataDirectory();
      final File file = File('${directory.path}/lamp_opencv_compare.txt');
      await file.writeAsString(report);
      return file.path;
    } on Object catch (e) {
      debugPrint('OPENCV файл не записан: $e');
      return 'не записан ($e)';
    }
  }

  /// Таблицы в 14 колонок на телефоне не читаются, поэтому на экран идёт
  /// только сводка расхождений и «центр − кольцо» — то, по чему видно,
  /// сходятся ли два способа. Полный текст остаётся в файле.
  Future<void> _showShadowReport(String report, String path) => showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      final List<String> lines = report.split('\n');
      final int summaryAt = lines.indexWhere(
        (String l) => l.startsWith('сводка расхождений'),
      );
      final String head = lines.isEmpty ? '' : lines.first;
      final String body = summaryAt < 0
          ? report
          : lines.sublist(summaryAt).join('\n');
      return AlertDialog(
        title: const Text('Сравнение способов (OpenCV)'),
        content: SingleChildScrollView(
          child: SelectableText(
            '$head\n\n$body\n\nфайл: $path',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      );
    },
  );

  /// Переключает СПОСОБ решения: цвет рамок или яркость четырёх областей.
  ///
  /// Переключается на лету и сохраняется: на стенде нельзя сравнивать
  /// алгоритмы, меняя сборку, — прогон делается один, а решение должно быть
  /// видно по экрану, а не по памяти оператора.
  void _toggleMode(DetectionSession session) {
    final bool nextSpatial = !session.config.spatialVectors;
    session.applyConfig(session.config.copyWith(spatialVectors: nextSpatial));
    unawaited(session.saveConfig());
    setState(
      () => _message = nextSpatial
          ? 'Решение: ЯРКОСТЬ + геометрия'
          : 'Решение: цвет (прежнее)',
    );
  }

  /// Чем именно мы сейчас работаем — короткая метка для лога.
  ///
  /// Способ решения (`spatialVectors`) переключается на экране, тень OpenCV —
  /// тоже, а в CSV и в logcat строки от обоих выглядят одинаково. Без этой
  /// метки разбирать потом нечем: «что, на ЯРКОСТИ столько намусорило?»
  String get _modeTag {
    final DetectionSession? s = _session;
    if (s == null) {
      return 'mode=?';
    }
    final String shadow = _shadow == null
        ? 'off'
        : 'on:${_shadow!.seen}';
    return 'mode=${s.config.spatialVectors ? "spatial" : "color"} '
        'ref=${s.config.liveReference ? "live" : "etalon"} '
        'shadow=$shadow';
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
        // Яркость обеих рамок и состояние лока: без этого не отличить вспышку
        // лампы от того, как автоэкспозиция пересчитала свет, и не увидеть
        // пересвет (Y упирается в 255).
        '| Y w=${f.white.meanY.toStringAsFixed(0)} '
        'r=${f.red.meanY.toStringAsFixed(0)} '
        // p90 — то, чем яркостной способ реально решает (`wf`/`rf` при
        // `spatialVectors` напечатаны для справки и на решение не влияют), а
        // `dark` — сколько длится текущий провал: по нему видно, ЗАЧЕМ канал
        // не отпускает («горит» навечно = провал не подтверждён).
        '| p90 w=${f.white.p90Luma.toStringAsFixed(0)} '
        'r=${f.red.p90Luma.toStringAsFixed(0)} '
        'dark W=${e?.whiteDarkMs ?? 0}ms R=${e?.redDarkMs ?? 0}ms '
        'exp=${s.exposureLocked ? "lock" : "auto"} '
        '| hits W=${s.whiteHits} R=${s.redHits}',
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

  static String _shortSession(String id) => id.length <= 8 ? id : id.substring(0, 8);

  @override
  Widget build(BuildContext context) {
    final DetectionSession? session = _session;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          session == null ? 'Lamp detection' : 'Lamp detection · ${_shortSession(session.sessionId)}',
        ),
        actions: <Widget>[
          if (session != null)
            PopupMenuButton<String>(
              onSelected: (String id) => _onMenu(id, session),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'mode',
                  child: Text(
                    session.config.spatialVectors
                        ? 'Решение: ЯРКОСТЬ + геометрия'
                        : 'Решение: цвет (прежнее)',
                  ),
                ),
                const PopupMenuItem<String>(value: 'calreset', child: Text('Сброс калибровки')),
                PopupMenuItem<String>(
                  value: 'shadow',
                  child: Text(
                    _shadow == null
                        ? 'Сравнить способы (OpenCV)'
                        : 'Отчёт OpenCV (${_shadow!.seen} кадров)',
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(value: 'log', child: Text('Журнал событий')),
                const PopupMenuItem<String>(value: 'errors', child: Text('Ошибки')),
              ],
            ),
        ],
      ),
      body: session == null
          ? Center(child: Text(_message))
          : SafeArea(
              child: Column(
                children: <Widget>[
                  _PrimaryControls(session: session, onRun: _toggleRun),
                  _CalibrationSteps(session: session, onStep: _calibrateStep),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
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
                                onChanged: (RoiLayout layout) => session.updateRoi(layout),
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
                    ),
                  ),
                  _ReadyBanner(
                    session: session,
                    onRelearn: () {
                      // Ровно то, ради чего раньше приходилось жать «Стоп» и
                      // снова «Пуск»: перемерить свет, не потеряв счётчики.
                      session.relearnLight();
                    },
                  ),
                  _StatusRow(
                    session: session,
                    onReset: () {
                      session.resetCounters();
                      setState(() => _message = 'Сброшено');
                    },
                  ),
                  _ModeStrip(
                    spatial: session.config.spatialVectors,
                    liveReference: session.config.liveReference,
                    shadowFrames: _shadow?.seen,
                    onToggleMode: () => _toggleMode(session),
                    onToggleShadow: () => _toggleShadow(session),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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

  Future<void> _onMenu(String id, DetectionSession session) async {
    switch (id) {
      case 'mode':
        _toggleMode(session);
      case 'calreset':
        _resetCalibration();
      case 'shadow':
        await _toggleShadow(session);
      case 'log':
        await _sheet('Журнал событий', EventLog(events: _events, statuses: _statuses));
      case 'errors':
        await _sheet(
          'Ошибки',
          ListView(
            padding: const EdgeInsets.all(12),
            children: _errors
                .map((String e) => Text(e, style: const TextStyle(fontSize: 12)))
                .toList(),
          ),
        );
    }
  }
}

/// Полоса «можно ли уже считать» и кнопка «перемерить свет».
///
/// Единственный вопрос оператора у лампы — не «жива ли программа», а «готово ли
/// считать». Пока ответа нет, экран обязан говорить, чего не хватает: камера,
/// калибровка или стабилизирующийся свет. Иначе тишина выглядит как зависшее
/// приложение, а это ровно то, на что жалуются после первого запуска.
///
/// Кнопка рядом с ней — по той же причине: навести рамки на колпаки можно только
/// ПОСЛЕ «Пуск», а «пол» живого отсчёта к этому моменту уже набран по фону и по
/// чужому месту в кадре. Раньше это лечилось только рестартом камеры.
class _ReadyBanner extends StatelessWidget {
  const _ReadyBanner({required this.session, required this.onRelearn});

  final DetectionSession session;
  final VoidCallback onRelearn;

  @override
  Widget build(BuildContext context) {
    final ({bool ready, String why}) state = session.readiness;
    final Color color = state.ready ? Colors.teal : Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              state.ready ? Icons.check_circle : Icons.hourglass_top,
              color: color,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                state.ready
                    ? 'ГОТОВ К РАБОТЕ'
                    : state.why,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: state.ready ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            // Отдельного экрана и пункта меню под это нет: действие нужно в
            // те секунды, когда руки уже держат телефон над табло.
            TextButton.icon(
              onPressed: onRelearn,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.autorenew, size: 16),
              label: const Text('СВЕТ ЗАНОВО', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryControls extends StatelessWidget {
  const _PrimaryControls({required this.session, required this.onRun});

  final DetectionSession session;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final LampStatus status = session.status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FilledButton.icon(
              onPressed: onRun,
              style: FilledButton.styleFrom(
                backgroundColor: status.running ? Colors.redAccent : Colors.teal,
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
  const _CalibrationSteps({required this.session, required this.onStep});

  final DetectionSession session;
  final Future<void> Function(CalibrationStep step) onStep;

  @override
  Widget build(BuildContext context) {
    final LampStatus s = session.status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        children: <Widget>[
          Row(
            children: CalibrationStep.values
                .map((CalibrationStep step) => Expanded(child: _button(step, s)))
                .toList(growable: false),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.calibrationError.isNotEmpty ? s.calibrationError : s.calibrationHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
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

/// Чем прибор сейчас работает — две кнопки-индикатора на главном экране.
///
/// Обе величины можно переключать, но до этого они были видны только внутри
/// всплывающего меню: оператор не мог, не открывая `⋮`, узнать каким способом
/// сегодня посчитаны его три события. Открывать меню ради ответа «как мы
/// работаем» — лишний тап, а сверить потом надо ровно это.
///
/// OpenCV здесь НЕ вторая линия решения: тень мерит рядом и не вправе создать
/// событие, поэтому она показана как измеритель, а не как режим.
class _ModeStrip extends StatelessWidget {
  const _ModeStrip({
    required this.spatial,
    required this.liveReference,
    required this.shadowFrames,
    required this.onToggleMode,
    required this.onToggleShadow,
  });

  final bool spatial;
  final bool liveReference;
  final int? shadowFrames;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleShadow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _chip(
              // Живой отсчёт и способ решения — разные оси: и то и то влияет на
              // порог, но меняется одно на лету, а другое только в конфиге.
              spatial
                  ? 'РЕШЕНИЕ: ЯРКОСТЬ + ГЕОМЕТРИЯ'
                  : 'РЕШЕНИЕ: ЦВЕТ (ПРЕЖНЕЕ)',
              spatial ? Colors.teal : Colors.blueGrey,
              onToggleMode,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _chip(
              shadowFrames == null
                  ? 'OpenCV: ВЫКЛ'
                  : 'OpenCV: $shadowFrames кадров',
              shadowFrames == null ? Colors.blueGrey : Colors.amber,
              onToggleShadow,
            ),
          ),
          const SizedBox(width: 6),
          _chip(
            liveReference ? 'ЖИВОЙ ПОЛ' : 'ЭТАЛОНЫ',
            Colors.grey,
            null,
          ),
        ],
      ),
    );
  }

  /// `_chip(..., null)` — только показывает и не нажимается.
  Widget _chip(String text, Color color, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.7)),
          ),
          alignment: Alignment.center,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.session, required this.onReset});

  final DetectionSession session;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final LampStatus status = session.status;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _counter('БЕЛАЯ', status.whiteHits, status.whiteLit, Colors.white),
          IconButton(
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Сбросить счётчики',
            color: Colors.grey,
          ),
          _counter('КРАСНАЯ', status.redHits, status.redLit, Colors.redAccent),
        ],
      ),
    );
  }

  Widget _counter(String label, int value, bool lit, Color color) => Column(
        children: <Widget>[
          Text('$value',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: lit ? color : Colors.grey,
              )),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
    final bool portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final double longSide = size.width >= size.height ? size.width : size.height;
    final double shortSide = size.width >= size.height ? size.height : size.width;
    final double aspect = portrait ? shortSide / longSide : longSide / shortSide;
    return Center(child: AspectRatio(aspectRatio: aspect, child: child));
  }
}
