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

/// Задержка обнаружения одной лампы, измеренная на записи (v6 §14: «Detection
/// latency»).
///
/// Мерится от ПЕРВОГО кадра, в котором подъём своей рамки стал выше своего
/// ON-уровня, до кадра, в котором событие подтверждено. Это ровно то время,
/// которое автомат берёт на «посмотреть несколько кадров подряд», и оно обязано
/// быть числом рядом с числом ошибок: правило подтверждения из двух кадров
/// дешёвое лишь пока его задержка ничего не стоит на стенде.
///
/// [misses] — сколько эпизодов подъёма так и не стали событием. Сам по себе
/// этот счётчик НЕ разделяет пропуск и правильный отказ: отказ отражению
/// соседней лампы выглядит здесь точно так же, как потерянный удар. Разделяет
/// их только человеческая разметка, поэтому число и печатается рядом с
/// [RunAnalysis.reflectionRefusals], а не вместо него.
final class RunLatency {
  const RunLatency({
    required this.lamp,
    required this.samplesMs,
    required this.misses,
  });

  final String lamp;

  /// Задержки подтверждённых событий в миллисекундах.
  final List<int> samplesMs;

  /// Эпизодов подъёма выше уровня, закончившихся без события.
  final int misses;

  bool get measured => samplesMs.isNotEmpty;

  int get medianMs {
    if (!measured) {
      return 0;
    }
    final List<int> sorted = List<int>.of(samplesMs)..sort();
    return sorted[sorted.length ~/ 2];
  }

  int get maxMs => measured ? samplesMs.reduce(math.max) : 0;

  String describe() =>
      '$lamp: задержка ${samplesMs.length} событ. '
      '${measured ? '(медиана $medianMs мс, максимум $maxMs мс)' : '(не измерена)'} · '
      'подъёмов без события $misses';
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
    required this.mode,
    required this.whiteLatency,
    required this.redLatency,
    required this.refusedFrames,
    required this.reflectionRefusals,
    required this.unknownFrames,
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

  /// Каким способом счёта запись была перерешена здесь. Обязано печататься:
  /// два режима v6 (`hsv` и `hsvCalibration`) на ОДНОЙ записи дают разные
  /// счёты событий, и без этой метки два разбира нельзя сравнить — их можно
  /// только перепутать.
  final String mode;

  /// Задержка обнаружения и число подъёмов без события (v6 §14).
  final RunLatency whiteLatency;
  final RunLatency redLatency;

  /// Сколько подъёмов профили отвергли, из них как отражение соседней лампы,
  /// и сколько кадров остались недоказанными. Ноль при включённом
  /// `hsvCalibration` значит, что калибровка профилей не набрана и решение
  /// молча осталось деревом v5; проверяется по [mode] и по строке
  /// `profileDecision` детектора.
  final int refusedFrames;
  final int reflectionRefusals;
  final int unknownFrames;

  String describe() => <String>[
    'кадров $frames за ${span.inMilliseconds} мс · медианный кадр $medianFrameMs мс',
    'режим разбора: $mode',
    'событий: белая $whiteEvents · красная $redEvents '
        '(подтверждение выключения было $offConfirmMs мс)',
    whiteTiming.describe(),
    redTiming.describe(),
    whiteLatency.describe(),
    redLatency.describe(),
    'профили: отказов $refusedFrames (отражение $reflectionRefusals), '
        'недоказанных кадров $unknownFrames',
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
    if (effective.hsvReference && baseline == null) {
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
    final _LatencyTracker whiteDelay = _LatencyTracker();
    final _LatencyTracker redDelay = _LatencyTracker();
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
      // Задержка меряется по тому же признаку, которым решается включение:
      // подъём выше своего ON-уровня. Событие (`on`) при этом — момент, когда
      // его подтвердил автомат, а не когда его выдал детектор кадра.
      whiteDelay.step(
        timestampMs: row.timestampMs,
        aboveOn: e.whiteAmplitude >= level,
        on: e.whiteOn,
      );
      redDelay.step(
        timestampMs: row.timestampMs,
        aboveOn: e.redAmplitude >= (detector.redOnLevel ?? 0),
        on: e.redOn,
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
      mode: effective.countMode.name,
      whiteLatency: whiteDelay.done('белая'),
      redLatency: redDelay.done('красная'),
      refusedFrames: detector.refusedFrames,
      reflectionRefusals: detector.reflectionRefusals,
      unknownFrames: detector.unknownFrames,
    );
  }

  /// Одна и та же запись, решённая ОБОИМИ цветовыми режимами v6.
  ///
  /// Делается одним вызовом специально: различие режимов обязано быть
  /// измерено на ОДНОЙ записи, а не на двух прогонах разного света — иначе
  /// сравнивать нечего, а правило приёмки v6 §7 требует ровно этого: новая
  /// схема обязана быть не хуже измеренного предыдущей сборки (60 ошибок на
  /// разметке заказчика, журнал 46). Режим `hsv` здесь и есть та прежняя
  /// схема, пересчитанная по тем же строкам.
  ///
  /// [baseline] обязана быть той же сессии, чей CSV: имена вспышек выучиваются
  /// по трём состояниям, и на другой калибровке разбор решил бы другую задачу.
  static RunAb analyzeBothModes(
    String csv, {
    LampConfig base = const LampConfig(),
    LampBaseline? baseline,
  }) => RunAb(
    plain: analyze(csv, base: base, mode: LampCountMode.hsv, baseline: baseline),
    profiled: analyze(
      csv,
      base: base,
      mode: LampCountMode.hsvCalibration,
      baseline: baseline,
    ),
  );
}

/// Одна запись, решённая режимом без профилей и режимом с ними.
final class RunAb {
  const RunAb({required this.plain, required this.profiled});

  /// `hsv` — ровно измеренное дерево v5, сверка для него и существует.
  final RunAnalysis plain;

  /// `hsvCalibration` — то же дерево плюс сверка кадра с профилями.
  final RunAnalysis profiled;

  /// На сколько событий профильный режим разошёлся с прежним. Знак важнее
  /// модуля: минус — профили сняли события (отказ отражению или потеря,
  /// различает только разметка), плюс — прежний режим считал там, где
  /// профили возражений не нашли.
  int get whiteDelta => profiled.whiteEvents - plain.whiteEvents;
  int get redDelta => profiled.redEvents - plain.redEvents;
  int get eventDelta => whiteDelta + redDelta;

  /// Что этот разбор значит, одними словами и без вывода за оператора: здесь
  /// нет числа «правильно», есть только направление разницы и её цена.
  String get verdict {
    if (eventDelta != 0) {
      return 'разница $eventDelta событий (белая $whiteDelta, красная '
          '$redDelta), отказов ${profiled.refusedFrames}, из них отражение '
          '${profiled.reflectionRefusals}: минус по разметке — это потеря, '
          'плюс — прежний режим ложно срабатывал';
    }
    if (profiled.refusedFrames > 0 || profiled.unknownFrames > 0) {
      return 'счёт совпал, но отказов было ${profiled.refusedFrames} '
          '(отражение ${profiled.reflectionRefusals}) и недоказанных кадров '
          '${profiled.unknownFrames}: профили мешали кадрам, а не событиям';
    }
    return 'счёт совпал с прежним режимом, отказов нет: на этой записи профили '
        'не изменили ничего — либо калибровка набрана без них, либо возражений '
        'не было';
  }

  String describe() => <String>[
    '=== ${plain.mode} (без профилей) ===',
    plain.describe(),
    '',
    '=== ${profiled.mode} (с профилями) ===',
    profiled.describe(),
    '',
    '=== разница ===',
    verdict,
  ].join('\n');
}

/// Накопитель задержки обнаружения одного канала (v6 §14).
class _LatencyTracker {
  final List<int> _ms = <int>[];
  int _misses = 0;

  /// Время первого кадра текущего подъёма выше ON-уровня; null, когда подъёма
  /// нет. Отсчёт ведётся по метке времени КАДРА, а не по их числу: на стенде
  /// частота кадров плывёт, и «два кадра» на 8 к/с — не те же 250 мс, что на
  /// 20 к/с.
  int? _startedAt;

  void step({
    required int timestampMs,
    required bool aboveOn,
    required bool on,
  }) {
    if (aboveOn) {
      _startedAt ??= timestampMs;
    }
    if (on) {
      final int? start = _startedAt;
      if (start != null) {
        _ms.add(timestampMs - start);
      }
      _startedAt = null;
      return;
    }
    // Подъём ушёл ниже уровня, а события не было: эпизод закрыт без открытия.
    if (!aboveOn && _startedAt != null) {
      _misses++;
      _startedAt = null;
    }
  }

  RunLatency done(String lamp) => RunLatency(
    lamp: lamp,
    samplesMs: List<int>.unmodifiable(_ms),
    misses: _misses,
  );
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
