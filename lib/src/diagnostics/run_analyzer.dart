import 'dart:math' as math;

import '../detection/hit_state_machine.dart';
import '../detection/lamp_detector.dart';
import '../models/frame_features.dart';
import '../models/hit_event.dart';
import '../models/lamp_config.dart';
import 'feature_csv_recorder.dart';

/// Длительности провалов сигнала одной лампы, измеренные на записи.
///
/// Это те самые числа, которых не хватало, чтобы перевести подтверждение
/// выключения из кадров в миллисекунды: `dipsMs` — насколько коротко амплитуда
/// падает ВНУТРИ одного горения (вспышка идёт волной), `pausesMs` — насколько
/// длительна пауза МЕЖДУ двумя настоящими ударами. Правило подтверждения обязано
/// лечь между этими двумя множествами, иначе оно либо считает один удар дважды,
/// либо склеит два удара в один.
class DarkRunTiming {
  const DarkRunTiming({
    required this.lamp,
    required this.dipsMs,
    required this.pausesMs,
    required this.maxOffRunMs,
  });

  /// Название канала — чтобы в сообщении не оставалось гадать, о чём речь.
  final String lamp;

  /// Провалы ниже OFF-уровня, после которых лампа снова загорела, НЕ дав new
  /// события: это внутриударная волна.
  final List<int> dipsMs;

  /// Провалы, после которых началось НОВОЕ подтверждённое событие: это пауза
  /// между ударами.
  final List<int> pausesMs;

  /// Самый длинный провал вообще — верхняя граница того, что детектор вообще
  /// видел «погасшим».
  final int maxOffRunMs;

  /// Самый длинный внутриударный провал.
  int get maxDipMs => dipsMs.isEmpty ? 0 : dipsMs.reduce(math.max);

  /// Кратчайшая настоящая пауза между ударами.
  int get minPauseMs => pausesMs.isEmpty ? 0 : pausesMs.reduce(math.min);

  /// Есть ли между ними зазор, в который вообще можно поставить правило.
  bool get separable =>
      dipsMs.isNotEmpty && pausesMs.isNotEmpty && maxDipMs < minPauseMs;

  /// Куда следовало бы поставить `offConfirmMs` по ЭТОЙ записи: середина между
  /// самым длинным провалом и самой короткой паузой. Null, если записи для
  /// вывода не хватает — тогда число остаётся прежним, а не угаданным.
  int? get suggestedOffConfirmMs =>
      separable ? (maxDipMs + minPauseMs) ~/ 2 : null;

  String describe() =>
      '$lamp: провалов ${dipsMs.length} (до $maxDipMs мс), пауз ${pausesMs.length} '
      '(от $minPauseMs мс) · '
      '${separable ? 'правило = $suggestedOffConfirmMs мс' : 'разделить нечем'}';
}

/// Итог разбора записанной серии.
class RunAnalysis {
  const RunAnalysis({
    required this.frames,
    required this.span,
    required this.medianFrameMs,
    required this.whiteEvents,
    required this.redEvents,
    required this.whiteTiming,
    required this.redTiming,
    required this.offConfirmMs,
  });

  final int frames;

  /// Длительность записи по меткам времени кадров.
  final Duration span;

  /// Медианный интервал между ОБРАБОТАННЫМИ кадрами (мс). Нужно помнить, что
  /// правило в кадрах на этой частоте означает другую длительность, чем на
  /// стенде: именно поэтому подтверждение выключения меряется временем.
  final int medianFrameMs;

  /// Сколько событий каждого цвета набралось на этой записи.
  final int whiteEvents;
  final int redEvents;

  final DarkRunTiming whiteTiming;
  final DarkRunTiming redTiming;

  /// Каким было `offConfirmMs` в этот прогон.
  final int offConfirmMs;

  String describe() => <String>[
    'кадров $frames за ${span.inMilliseconds} мс · медианный кадр $medianFrameMs мс',
    'событий: белая $whiteEvents · красная $redEvents '
        '(подтверждение выключения было $offConfirmMs мс)',
    whiteTiming.describe(),
    redTiming.describe(),
  ].join('\n');
}

/// Разбор записанной серии (CSV v5 и старых форматов) нынешним способом решения.
///
/// Здесь когда-то жил `ModeComparator`, прогонявший ОДНУ запись двумя способами
/// — цветовым и яркостным, — чтобы новое решение не отменяло старую реализацию,
/// а сравнивалось с ней на одних и тех же измеренных признаках. Цветовое
/// решение удалено: пересвеченная красная лампа для сенсора белая, и её вспышка
/// уезжала в белую корзину, а на «прежнем» способе это воспроизводилось.
/// Сравнивать больше не с чем, поэтому остался один прогон.
///
/// Главная задача здесь теперь одна, и она важнее подсчёта событий: по тем же
/// строкам измеряются длительности провалов и пауз ([DarkRunTiming]), то есть
/// правило подтверждения выключения получает числа от записи, а не от догадки.
///
/// Разбор идёт тем же способом, каким считалась сама запись: [mode] (или
/// [LampConfig.countMode] в [base]). Прежнее принудительное `liveReference: true`
/// делало HSV-прогон непроверяемым: запись, решённая по цвету, пересчитывалась
/// по яркости и давала другой счёт событий, который нельзя было сравнить ни с
/// чем (ЖУРНАЛ §11.12).
///
/// Калибровка разбору нужна ровно та же, что и живому прогону. HSV-счёт
/// называется по выученному правилу, а оно учится по трём состояниям калибровки;
/// без [baseline] тот же CSV решился бы перевесом канала — то есть способом,
/// который с 25.11.2026 рабочим не считается (журнал 46). Разбор обязан назвать
/// число ошибок того способа, которым считали, а не подменять его другим, поэтому
/// без калибровки он не запускается вовсе. [baseline] берут из сессии, чей это
/// CSV.
class RunAnalyzer {
  const RunAnalyzer();

  static RunAnalysis analyze(
    String csv, {
    LampConfig base = const LampConfig(),
    LampCountMode? mode,
    LampBaseline? baseline,
  }) {
    final List<FeatureCsvRow> rows = FeatureCsv.decode(csv);
    if (rows.length < 2) {
      throw ArgumentError('для разбора нужно минимум два кадра записи');
    }

    final LampConfig effective = mode == null ? base : base.withCountMode(mode);
    if (effective.countMode == LampCountMode.hsv && baseline == null) {
      throw ArgumentError(
        'HSV-разбор без калибровки: удары назвали бы перевесом канала, а не '
        'выученным правилом — это другой способ, а не тот, которым считали '
        'запись (журнал 46). Передайте baseline сессии.',
      );
    }

    final LampDetector detector = LampDetector(effective);
    if (baseline != null) {
      detector.setBaseline(baseline);
    }
    final HitStateMachine machine = HitStateMachine(sessionId: 'analysis');
    final _Tracker white = _Tracker();
    final _Tracker red = _Tracker();
    int whiteEvents = 0;
    int redEvents = 0;
    for (final FeatureCsvRow row in rows) {
      final LampEvaluation e = detector.evaluate(row.toLampFrame());
      for (final HitEvent event in machine.onEvaluation(e)) {
        if (event.color == HitColor.white) {
          whiteEvents++;
        } else {
          redEvents++;
        }
      }
      final double level = detector.whiteOnLevel ?? 0;
      white.step(
        darkMs: e.whiteDarkMs,
        on: e.whiteOn,
        off: e.whiteOff,
        lit: e.whiteLit,
        back: e.whiteAmplitude >= level,
      );
      red.step(
        darkMs: e.redDarkMs,
        on: e.redOn,
        off: e.redOff,
        lit: e.redLit,
        back: e.redAmplitude >= (detector.redOnLevel ?? 0),
      );
    }

    final List<int> deltas = <int>[];
    for (int i = 1; i < rows.length; i++) {
      deltas.add(rows[i].timestampMs - rows[i - 1].timestampMs);
    }
    deltas.sort();

    return RunAnalysis(
      frames: rows.length,
      span: Duration(
        milliseconds: rows.last.timestampMs - rows.first.timestampMs,
      ),
      medianFrameMs: deltas[deltas.length ~/ 2],
      whiteEvents: whiteEvents,
      redEvents: redEvents,
      whiteTiming: white.done('белая'),
      redTiming: red.done('красная'),
      offConfirmMs: base.offConfirmMs,
    );
  }
}

/// Накопитель интервалов «не выше ON-уровня» одного канала.
///
/// Разделение простое и целиком по факту событий: если после провала началось
/// НОВОЕ событие — до него было подтверждённое гашение, значит это пауза между
/// ударами; если же амплитуда вернулась, а события нет — горение не прерывали,
/// значит это волна внутри одного удара.
class _Tracker {
  final List<int> _dips = <int>[];
  final List<int> _pauses = <int>[];

  /// Пик текущего интервала «не выше ON».
  int _peak = 0;

  /// Было ли в этом интервале подтверждённое гашение.
  bool _sawOff = false;

  /// Было ли вообще хотя бы одно событие: провал ДО первой вспышки (то, с чего
  /// запись начинается) ни пауза, ни волна — это просто темнота до начала
  /// измерений.
  bool _burned = false;

  int _max = 0;

  void step({
    required int darkMs,
    required bool on,
    required bool off,
    required bool lit,
    required bool back,
  }) {
    if (darkMs > _peak) {
      _peak = darkMs;
    }
    if (darkMs > _max) {
      _max = darkMs;
    }
    if (off) {
      _sawOff = true;
    }
    if (on) {
      _burned = true;
      // Событие возможно только после подтверждённого гашения — либо из
      // стартового «ещё ничего не горело», где провалом считать нечего.
      if (_sawOff && _peak > 0) {
        _pauses.add(_peak);
      }
      _peak = 0;
      _sawOff = false;
      return;
    }
    // Амплитуда вернулась выше уровня, а события нет — канал горел всё это
    // время: провал был внутриударным.
    if (_burned && back && lit && _peak > 0) {
      _dips.add(_peak);
      _peak = 0;
      _sawOff = false;
    }
  }

  DarkRunTiming done(String lamp) => DarkRunTiming(
    lamp: lamp,
    dipsMs: List<int>.unmodifiable(_dips),
    pausesMs: List<int>.unmodifiable(_pauses),
    maxOffRunMs: _max,
  );
}
