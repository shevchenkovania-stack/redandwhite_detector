import 'dart:convert' show LineSplitter;
import 'dart:io';

import '../models/frame_features.dart';

/// Одна строка CSV диагностики.
///
/// Формат v3 (41 колонка). Колонки 0–26 — формат v2 без изменений:
/// `timestamp_ms, white_meanY, red_meanY, state, white_whiteFrac,
/// red_redFrac, white_redFrac, red_whiteFrac, calibration_step,
/// white_ring_whiteFrac, white_ring_redFrac, red_ring_whiteFrac,
/// red_ring_redFrac, white_rise, red_rise, white_level, red_level, lit_white,
/// lit_red, on_white, on_red, off_white, off_red, ambiguous, unexplained,
/// exposure_ns, sensitivity`. Колонки 27–40 — яркость четырёх областей, из
/// которой собирается пространственный отклик: `white_p90, white_std,
/// white_clip, red_p90, red_std, red_clip, white_ring_meanY,
/// white_ring_p90, white_ring_std, white_ring_clip, red_ring_meanY,
/// red_ring_p90, red_ring_std, red_ring_clip`.
///
/// Первый блок (до `calibration_step`) — вектор признаков обеих РАМОК, из
/// которого собираются эталоны: по нему калибровка восстанавливается целиком.
/// Кольца записываются потому, что в режиме живого отсчёта решение принимается
/// именно по подъёму в кольце (`*_ring_*`), а без этих колонок файл не
/// воспроизводит то, что реально увидел детектор. `*_rise` и `*_level` —
/// подъём и порог того же кадра, `lit_*`/`on_*`/`off_*` — состояние и
/// подтверждённые переходы гистерезиса, `exposure_ns`/`sensitivity` —
/// автоэкспозиция (по ней видно, что сцена посветлела сама, без лампы).
/// `calibration_step` — метка шага (`bg` | `white_on` | `red_on`) или пусто для
/// рабочего прогона.
///
/// Цветные доли (`*_whiteFrac`, `*_redFrac`) пишутся и дальше: в решении они
/// больше не участвуют, но без них нельзя сравнить старый и новый алгоритм на
/// ОДНОЙ записи — а другого способа сравнить их на стенде нет.
///
/// Старые файлы читаются по числу колонок: 27–40 — формат v2 (яркостных
/// признаков в нём нет, они считаются нулём), 10–26 — формат v1
/// (`brightFrac`/`sat`/`redDom`/`coreEdgeDiff`, если 10, или прежние шесть),
/// кольца и решение по ним считаются нулём; 6–9 — прежние колонки рамок.
class FeatureCsvRow {
  const FeatureCsvRow({
    required this.timestampMs,
    required this.white,
    required this.red,
    required this.state,
    this.whiteRing,
    this.redRing,
    this.whiteRise = 0,
    this.redRise = 0,
    this.whiteLevel = 0,
    this.redLevel = 0,
    this.whiteLit = false,
    this.redLit = false,
    this.whiteOn = false,
    this.redOn = false,
    this.whiteOff = false,
    this.redOff = false,
    this.ambiguous = false,
    this.unexplained = false,
    this.exposureTimeNs,
    this.sensorSensitivity,
    this.calibrationStep = '',
  });

  static const String header =
      'timestamp_ms,white_meanY,red_meanY,state,white_whiteFrac,red_redFrac,'
      'white_redFrac,red_whiteFrac,calibration_step,white_ring_whiteFrac,'
      'white_ring_redFrac,red_ring_whiteFrac,red_ring_redFrac,white_rise,'
      'red_rise,white_level,red_level,lit_white,lit_red,on_white,on_red,'
      'off_white,off_red,ambiguous,unexplained,exposure_ns,sensitivity,'
      'white_p90,white_std,white_clip,red_p90,red_std,red_clip,'
      'white_ring_meanY,white_ring_p90,white_ring_std,white_ring_clip,'
      'red_ring_meanY,red_ring_p90,red_ring_std,red_ring_clip';

  /// Число колонок формата v3: короче строка — записана старой сборкой.
  static const int currentColumnCount = 41;

  /// Число колонок формата v2: яркость областей в нём ещё не писалась, но
  /// индексы 0–26 совпадают с v3, поэтому читается тем же разбором.
  static const int columnsV2 = 27;

  final int timestampMs;
  final FrameFeatures white;
  final FrameFeatures red;

  /// Состояние автомата в этот момент (idle | whiteOn | redOn).
  final String state;

  /// Кольца вокруг рамок (ореол). Null, если кольцо выключено.
  final FrameFeatures? whiteRing;
  final FrameFeatures? redRing;

  /// Амплитуда и ON-уровень каждой лампы тем же кадром, что видит UI.
  final double whiteRise;
  final double redRise;
  final double whiteLevel;
  final double redLevel;

  /// Состояние гистерезиса и подтверждённые им переходы этого кадра.
  final bool whiteLit;
  final bool redLit;
  final bool whiteOn;
  final bool redOn;
  final bool whiteOff;
  final bool redOff;

  /// Кадр, в котором обе лампы выше своего уровня, и кадр «не похоже ни на одну
  /// лампу».
  final bool ambiguous;
  final bool unexplained;

  /// Экспозиция сенсора и чувствительность — evidence автоэкспозиции.
  final int? exposureTimeNs;
  final double? sensorSensitivity;

  /// Метка шага калибровки, к которому относится кадр, — пусто для прогона.
  final String calibrationStep;

  String toCsvLine() => <Object>[
    timestampMs,
    white.meanY.toStringAsFixed(3),
    red.meanY.toStringAsFixed(3),
    state,
    white.whiteFrac.toStringAsFixed(5),
    red.redFrac.toStringAsFixed(5),
    white.redFrac.toStringAsFixed(5),
    red.whiteFrac.toStringAsFixed(5),
    calibrationStep,
    _frac(whiteRing?.whiteFrac),
    _frac(whiteRing?.redFrac),
    _frac(redRing?.whiteFrac),
    _frac(redRing?.redFrac),
    whiteRise.toStringAsFixed(5),
    redRise.toStringAsFixed(5),
    whiteLevel.toStringAsFixed(5),
    redLevel.toStringAsFixed(5),
    _bit(whiteLit),
    _bit(redLit),
    _bit(whiteOn),
    _bit(redOn),
    _bit(whiteOff),
    _bit(redOff),
    _bit(ambiguous),
    _bit(unexplained),
    exposureTimeNs ?? '',
    sensorSensitivity?.toStringAsFixed(1) ?? '',
    _lum(white.p90Luma),
    _lum(white.lumaStdDev),
    _frac(white.clippedRatio),
    _lum(red.p90Luma),
    _lum(red.lumaStdDev),
    _frac(red.clippedRatio),
    _lum(whiteRing?.meanY),
    _lum(whiteRing?.p90Luma),
    _lum(whiteRing?.lumaStdDev),
    _frac(whiteRing?.clippedRatio),
    _lum(redRing?.meanY),
    _lum(redRing?.p90Luma),
    _lum(redRing?.lumaStdDev),
    _frac(redRing?.clippedRatio),
  ].join(',');

  static String _frac(double? v) => v?.toStringAsFixed(5) ?? '';
  static String _lum(double? v) => v?.toStringAsFixed(2) ?? '';
  static String _bit(bool v) => v ? '1' : '0';

  /// Кадр для прогона детектора без камеры. Кольца обязательно едут вместе с
  /// рамками: в живом отсчёте решение принимает именно кольцо.
  LampFrame toLampFrame() => LampFrame(
    timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
    white: white,
    red: red,
    whiteRing: whiteRing,
    redRing: redRing,
    exposureTimeNs: exposureTimeNs,
    sensorSensitivity: sensorSensitivity,
  );

  factory FeatureCsvRow.parse(String line) {
    final List<String> c = line.split(',');
    if (c.length < 6) {
      throw FormatException('Строка CSV должна содержать не меньше 6 полей: "$line"');
    }
    final bool v3 = c.length >= currentColumnCount;
    // Индексы 0–26 у v3 и v2 совпадают, поэтому всё, что записано до
    // `sensitivity`, читается одним и тем же условием `modern`.
    final bool v2 = !v3 && c.length >= columnsV2;
    final bool modern = v3 || v2;
    final bool legacy = !modern && c.length >= 10;
    final bool v0 = !modern && !legacy && c.length >= 9;
    double d(int i) => double.parse(c[i]);
    // Недостаток колонок = признак не записывался: 0 честнее, чем догадка.
    double opt(int i) => i < c.length ? double.parse(c[i]) : 0;
    double? num(int i) => modern && c[i].isNotEmpty ? double.parse(c[i]) : null;
    double? lum(int i) => v3 && c[i].isNotEmpty ? double.parse(c[i]) : null;
    double val(int i) => lum(i) ?? 0;
    int? int_(int i) => modern && c[i].isNotEmpty ? int.parse(c[i]) : null;
    bool bit(int i) => modern && c[i] == '1';
    FrameFeatures? ring(int w, int r, int y, int p, int s, int cl) =>
        modern && (c[w].isNotEmpty || c[r].isNotEmpty)
            ? FrameFeatures(
                meanY: val(y),
                sampleCount: 0,
                whiteFrac: num(w) ?? 0,
                redFrac: num(r) ?? 0,
                p90Luma: val(p),
                lumaStdDev: val(s),
                clippedRatio: val(cl),
              )
            : null;
    return FeatureCsvRow(
      timestampMs: int.parse(c[0]),
      white: FrameFeatures(
        meanY: d(1),
        sampleCount: 0,
        whiteFrac: legacy ? d(8) : d(4),
        redFrac: modern || v0 ? opt(6) : 0,
        p90Luma: val(27),
        lumaStdDev: val(28),
        clippedRatio: val(29),
      ),
      red: FrameFeatures(
        meanY: legacy ? d(4) : d(2),
        sampleCount: 0,
        redFrac: legacy ? d(9) : d(5),
        whiteFrac: modern || v0 ? opt(7) : 0,
        p90Luma: val(30),
        lumaStdDev: val(31),
        clippedRatio: val(32),
      ),
      state: legacy ? c[7] : c[3],
      whiteRing: ring(9, 10, 33, 34, 35, 36),
      redRing: ring(11, 12, 37, 38, 39, 40),
      whiteRise: num(13) ?? 0,
      redRise: num(14) ?? 0,
      whiteLevel: num(15) ?? 0,
      redLevel: num(16) ?? 0,
      whiteLit: bit(17),
      redLit: bit(18),
      whiteOn: bit(19),
      redOn: bit(20),
      whiteOff: bit(21),
      redOff: bit(22),
      ambiguous: bit(23),
      unexplained: bit(24),
      exposureTimeNs: int_(25),
      sensorSensitivity: num(26),
      calibrationStep: modern || v0 ? c[8].trim() : '',
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
  ///
  /// Запись ведётся на каждый обработанный кадр, поэтому перед стартом
  /// остаются только [maxKeptFiles] самых свежих файлов: иначе многодневные
  /// прогоны забивают приватный каталог устройства, а такой «сюрприз» ловится
  /// уже на снятом CSV.
  Future<void> start(String sessionId) async {
    await stop();
    await _prune();
    final String stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.TZ]'), '');
    _file = File('${directory.path}${Platform.pathSeparator}${fileNamePrefix}_${stamp}_$sessionId.csv');
    final IOSink sink = _file!.openWrite(mode: FileMode.write);
    sink.writeln(FeatureCsvRow.header);
    _sink = sink;
    _buffered = 0;
    _lines = 0;
  }

  /// Сколько файлов записи оставляем после старта новой.
  static const int maxKeptFiles = 3;

  Future<void> _prune() async {
    try {
      final List<File> files = directory
          .listSync()
          .whereType<File>()
          .where((File f) => f.uri.pathSegments.last.startsWith(fileNamePrefix))
          .toList()
        ..sort((File a, File b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final File f in files.skip(maxKeptFiles)) {
        await f.delete();
      }
    } on Object {
      // Каталог мог ещё не существовать или быть занят — запись важнее
      // уборки, поэтому молча продолжаем.
    }
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
