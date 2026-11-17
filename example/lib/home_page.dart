import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

import 'widgets/diagnostics_panel.dart';
import 'widgets/decoder_sheet.dart';
import 'widgets/event_log.dart';
import 'widgets/roi_editor.dart';

/// Демо детекции. На экране только главное: превью, «Пуск», «Найти лампы»,
/// «Калибровка» и счётчик. Настройки/журнал/диагностика — в меню «⋮».
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DetectionSession? _session;
  MockHitEventSender? _sender;
  SqliteEventRepository? _repository;
  final List<HitEvent> _events = <HitEvent>[];
  final Map<String, String> _statuses = <String, String>{};
  final List<String> _errors = <String>[];
  String _message = 'инициализация…';
  bool _offline = false;
  int _mappingTurns = 0;
  StreamSubscription<HitEvent>? _hitsSub;
  StreamSubscription<String>? _errorsSub;
  bool _logNumbers = false;
  Timer? _logTimer;

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
      await session.loadSettings();
      session.addListener(_onSessionChanged);
      _hitsSub = session.hits.listen(_onHit);
      _errorsSub = session.errors.listen(
        (String message) => setState(() => _errors.insert(0, message)),
      );
      setState(() {
        _session = session;
        _sender = sender;
        _message = 'Нажми «Пуск», потом «Найти лампы».';
      });
      // Камера показывается сразу, без нажатия «Пуск».
      try {
        await session.start();
        if (!mounted) {
          return;
        }
        setState(() => _message = session.isCalibrated
            ? 'Камера активна (калибровка загружена)'
            : 'Камера активна. «Найти лампы» → «Калибровка».');
      } on Object catch (e) {
        if (!mounted) {
          return;
        }
        setState(() => _message = 'Камера не запустилась: $e');
      }
    } on Object catch (e) {
      setState(() => _message = 'Инициализация не удалась: $e');
    }
  }

  void _onSessionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onHit(HitEvent event) {
    setState(() {
      _events.insert(0, event);
      _message = 'Событие ${event.lampId} #${event.sequenceNumber} (записано в SQLite)';
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
    _session?.removeListener(_onSessionChanged);
    unawaited(_session?.dispose());
    super.dispose();
  }

  Future<void> _toggleRun() async {
    final DetectionSession session = _session!;
    if (session.isRunning) {
      await session.stop();
      setState(() => _message = 'Остановлено, камера освобождена');
      return;
    }
    setState(() => _message = 'Запуск камеры…');
    await session.start();
    setState(() => _message = session.isCalibrated
        ? 'Идёт детекция (калибровка загружена)'
        : 'Камера запущена. Нажми «Найти лампы», затем «Калибровка».');
  }

  /// Автоматический поиск зон ламп по текущему кадру.
  Future<void> _locate() async {
    final DetectionSession session = _session!;
    final RoiLayout? layout = session.autoLocateLamps();
    setState(() => _message = layout == null
        ? 'Нет кадра — сначала «Пуск».'
        : 'Лампы найдены. Держи обе выключенными и жми «Калибровка».');
  }

  Future<void> _calibrate() async {
    final DetectionSession session = _session!;
    setState(() => _message = 'Калибровка: держите обе лампы выключенными…');
    try {
      final LampBaseline baseline = await session.calibrate();
      setState(() => _message = 'Калибровка ${baseline.frameCount} кадров: '
          'σ white=${baseline.whiteNoise.toStringAsFixed(3)}, '
          'σ red=${baseline.redNoise.toStringAsFixed(3)}');
    } on Object catch (e) {
      setState(() => _message = 'Калибровка не удалась: $e');
    }
  }

  Future<void> _newSession() async {
    await _session!.newSession();
    setState(() {
      _events.clear();
      _statuses.clear();
      _message = 'Новая сессия: ${_session!.sessionId}';
    });
  }

  Future<void> _toggleNetwork() async {
    _sender!.offline = !_offline;
    setState(() {
      _offline = !_offline;
      _message = _offline ? 'Сеть выключена (mock)' : 'Сеть включена — отправляю pending';
    });
    if (!_offline) {
      await _session!.deliverPending();
    }
    await _refreshStatuses();
  }

  Future<void> _toggleCsv(bool turnOff) async {
    final DetectionSession session = _session!;
    await session.setRecordingCsv(!turnOff);
    setState(() => _message = session.status.csvPath ?? 'CSV выключен');
  }

  void _rotate() {
    _session!.setFrameMapping(++_mappingTurns % 4);
    setState(() => _message = 'Поворот ROI: ${_mappingTurns % 4} × 90°');
  }

  /// Включает/выключает поток чисел в logcat (тег LAMPDBG) — примерно 5 раз/с.
  void _toggleLogNumbers() {
    setState(() => _logNumbers = !_logNumbers);
    _logTimer?.cancel();
    _logTimer = null;
    if (_logNumbers) {
      _logTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _dumpNumbers());
      setState(() => _message = 'Лог чисел ВКЛ (тег LAMPDBG)');
    } else {
      setState(() => _message = 'Лог чисел выкл');
    }
  }

  /// Компактная строка с теми же величинами, что и на экране «Расшифровка».
  void _dumpNumbers() {
    final DetectionSession? s = _session;
    final LampFrame? f = s?.lastFeatures;
    if (s == null || f == null) {
      return;
    }
    final LampEvaluation? e = s.lastEvaluation;
    final LampBaseline? b = s.baseline;
    debugPrint(
      'LAMPDBG '
      'W wf=${f.white.whiteFrac.toStringAsFixed(3)} '
      'base=${(b?.white.whiteFrac ?? 0).toStringAsFixed(3)} '
      'ws=${(e?.whiteScore ?? 0).toStringAsFixed(2)} '
      '| R rf=${f.red.redFrac.toStringAsFixed(3)} '
      'base=${(b?.red.redFrac ?? 0).toStringAsFixed(3)} '
      'rs=${(e?.redScore ?? 0).toStringAsFixed(2)} '
      '| lit W=${e?.whiteLit ?? false} R=${e?.redLit ?? false} '
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
                  value: 'csv',
                  child: Text(session.status.recordingCsv ? 'CSV: ВКЛ' : 'CSV: выкл'),
                ),
                const PopupMenuItem<String>(value: 'network', child: Text('Сеть вкл/выкл')),
                const PopupMenuItem<String>(value: 'rotate', child: Text('Поворот ROI 90°')),
                PopupMenuItem<String>(value: 'lognum', child: Text(_logNumbers ? 'Лог чисел: ВКЛ' : 'Лог чисел: выкл')),
                const PopupMenuItem<String>(value: 'session', child: Text('Новая сессия')),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(value: 'decode', child: Text('Расшифровка чисел')),
                const PopupMenuItem<String>(value: 'log', child: Text('Журнал событий')),
                const PopupMenuItem<String>(value: 'diag', child: Text('Диагностика')),
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
                  _PrimaryControls(session: session, onLocate: _locate, onRun: _toggleRun, onCalibrate: _calibrate),
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _StatusRow(
                    session: session,
                    onReset: () {
                      session.resetCounters();
                      setState(() => _message = 'Счётчики сброшены');
                    },
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
      case 'csv':
        await _toggleCsv(session.status.recordingCsv);
      case 'network':
        await _toggleNetwork();
      case 'rotate':
        _rotate();
      case 'lognum':
        _toggleLogNumbers();
      case 'session':
        await _newSession();
      case 'decode':
        await _sheet('Расшифровка чисел', DecoderSheet(session: session));
      case 'log':
        await _sheet('Журнал событий', EventLog(events: _events, statuses: _statuses));
      case 'diag':
        await _sheet(
          'Диагностика',
          DiagnosticsPanel(
            session: session,
            message: _message,
            dataDirectory: session.csvRecorder.directory.path,
          ),
        );
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

class _PrimaryControls extends StatelessWidget {
  const _PrimaryControls({
    required this.session,
    required this.onRun,
    required this.onLocate,
    required this.onCalibrate,
  });

  final DetectionSession session;
  final VoidCallback onRun;
  final VoidCallback onLocate;
  final Future<void> Function() onCalibrate;

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
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: status.running ? onLocate : null,
              icon: const Icon(Icons.my_location),
              label: const Text('Найти лампы'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: status.running && !status.calibrating
                  ? () => onCalibrate()
                  : null,
              icon: const Icon(Icons.tune),
              label: Text(status.calibrating
                  ? '${status.calibration.collected}/${status.calibration.needed}'
                  : 'Калибровка'),
            ),
          ),
        ],
      ),
    );
  }
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
