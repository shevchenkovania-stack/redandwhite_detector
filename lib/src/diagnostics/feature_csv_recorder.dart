import 'dart:convert' show LineSplitter;
import 'dart:io';

import '../models/frame_features.dart';

/// Одна строка CSV диагностики.
///
/// Формат: `timestamp_ms, white_meanY, white_brightFrac, white_sat, red_meanY,
/// red_redDom, red_coreEdgeDiff, state, white_whiteFrac, red_redFrac`.
/// Последние два столбца — признаки, по которым считаются whiteScore/redScore.
/// Старые файлы (8 столбцов) читаются, но без них красная не воспроизводится.
class FeatureCsvRow {
  const FeatureCsvRow({
    required this.timestampMs,
    required this.white,
    required this.red,
    required this.state,
  });

  static const String header =
      'timestamp_ms,white_meanY,white_brightFrac,white_sat,red_meanY,red_redDom,red_coreEdgeDiff,state,'
      'white_whiteFrac,red_redFrac';

  final int timestampMs;
  final FrameFeatures white;
  final FrameFeatures red;

  /// Состояние автомата в этот момент (idle | whiteOn | redOn).
  final String state;

  String toCsvLine() => <Object>[
    timestampMs,
    white.meanY.toStringAsFixed(3),
    white.brightFrac.toStringAsFixed(5),
    white.sat.toStringAsFixed(5),
    red.meanY.toStringAsFixed(3),
    red.redDom.toStringAsFixed(3),
    red.coreEdgeDiff.toStringAsFixed(3),
    state,
    white.whiteFrac.toStringAsFixed(5),
    red.redFrac.toStringAsFixed(5),
  ].join(',');

  /// Кадр для прогона детектора без камеры.
  LampFrame toLampFrame() => LampFrame(
    timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
    white: white,
    red: red,
  );

  factory FeatureCsvRow.parse(String line) {
    final List<String> c = line.split(',');
    if (c.length < 8) {
      throw FormatException('Строка CSV должна содержать 8 полей: "$line"');
    }
    double d(int i) => double.parse(c[i]);
    return FeatureCsvRow(
      timestampMs: int.parse(c[0]),
      white: FrameFeatures(
        meanY: d(1),
        brightFrac: d(2),
        sat: d(3),
        redDom: 0,
        coreEdgeDiff: 0,
        sampleCount: 0,
        // Старый файл без whiteFrac: brightFrac — грубая замена.
        whiteFrac: c.length >= 10 ? d(8) : d(2),
      ),
      red: FrameFeatures(
        meanY: d(4),
        brightFrac: 0,
        sat: 0,
        redDom: d(5),
        coreEdgeDiff: d(6),
        sampleCount: 0,
        redFrac: c.length >= 10 ? d(9) : 0,
      ),
      state: c[7],
    );
  }
}

/// Разбор и сборка CSV целиком — для тестов и прогона детектора на записи.
class FeatureCsv {
  /// Пропускает заголовок и пустые строки.
  static List<FeatureCsvRow> decode(String content) {
    final List<FeatureCsvRow> rows = <FeatureCsvRow>[];
    for (final String line in const LineSplitter().convert(content)) {
      if (line.trim().isEmpty || line.startsWith('timestamp_ms')) {
        continue;
      }
      rows.add(FeatureCsvRow.parse(line));
    }
    return rows;
  }

  static String encode(Iterable<FeatureCsvRow> rows) =>
      '${FeatureCsvRow.header}\n${rows.map((FeatureCsvRow r) => r.toCsvLine()).join('\n')}\n';
}

/// Пишет CSV построчно в файл в указанном каталоге.
class FeatureCsvRecorder {
  FeatureCsvRecorder({
    required this.directory,
    this.bufferLines = 30,
    this.fileNamePrefix = 'lamp_features',
  });

  final Directory directory;

  /// Сколько строк держать в буфере перед записью на диск.
  final int bufferLines;

  final String fileNamePrefix;

  IOSink? _sink;
  File? _file;
  int _buffered = 0;
  int _lines = 0;

  bool get isRecording => _sink != null;
  int get lineCount => _lines;
  String? get filePath => _file?.path;

  /// Создаёт файл с заголовком. Имя содержит session id и время старта.
  Future<void> start(String sessionId) async {
    await stop();
    final String stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.TZ]'), '');
    _file = File('${directory.path}${Platform.pathSeparator}${fileNamePrefix}_${stamp}_$sessionId.csv');
    final IOSink sink = _file!.openWrite(mode: FileMode.write);
    sink.writeln(FeatureCsvRow.header);
    _sink = sink;
    _buffered = 0;
    _lines = 0;
  }

  Future<void> write(FeatureCsvRow row) async {
    final IOSink? sink = _sink;
    if (sink == null) {
      return;
    }
    sink.writeln(row.toCsvLine());
    _lines++;
    _buffered++;
    if (_buffered >= bufferLines) {
      await flush();
    }
  }

  Future<void> flush() async {
    await _sink?.flush();
    _buffered = 0;
  }

  /// Закрывает файл и возвращает его. После stop() запись невозможна.
  Future<File?> stop() async {
    final IOSink? sink = _sink;
    _sink = null;
    if (sink != null) {
      await sink.flush();
      await sink.close();
    }
    return _file;
  }
}
