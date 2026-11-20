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

/// Результат сравнения двух способов решения на одной и той же записи.
class ModeComparison {
  const ModeComparison({
    required this.frames,
    required this.span,
    required this.medianFrameMs,
    required this.legacyWhiteEvents,
    required this.legacyRedEvents,
    required this.spatialWhiteEvents,
    required this.spatialRedEvents,
    required this.mismatches,
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

  final int legacyWhiteEvents;
  final int legacyRedEvents;
  final int spatialWhiteEvents;
  final int spatialRedEvents;

  /// Короткие строки, где способы разошлись: время и кто из них что решил.
  final List<String> mismatches;

  final DarkRunTiming whiteTiming;
  final DarkRunTiming redTiming;

  /// Каким было `offConfirmMs` в этот прогон.
  final int offConfirmMs;

  /// Совпали ли числа событий во всех четырёх каналах.
  bool get countsAgree =>
      legacyWhiteEvents == spatialWhiteEvents && legacyRedEvents == spatialRedEvents;

  String describe() => <String>[
      'кадров $frames за ${span.inMilliseconds} мс · медианный кадр $medianFrameMs мс',
      'цвет: W=$legacyWhiteEvents R=$legacyRedEvents · '
          'яркость: W=$spatialWhiteEvents R=$spatialRedEvents '
          '${countsAgree ? '(совпало)' : '(РАЗОШЛОСЬ)'}',
      whiteTiming.describe(),
      redTiming.describe(),
      if (mismatches.isNotEmpty) 'расхождения: ${mismatches.join('; ')}',
    ].join('\n');
}

/// Прогон одной записи двумя способами решения — цветовым и пространственным.
///
/// Сравнивать их иначе нельзя: оба читают ОДНИ и ТЕ ЖЕ измеренные признаки из
/// CSV v3, где записаны и цветовые доли, и яркость четырёх областей. Любое
/// «новый алгоритм лучше» без такой пары — просто два разных прогона стенда, а
/// не сравнение алгоритмов.
///
/// Третья задача здесь даже важнее первой: по тем же строкам измеряются
/// длительности провалов и пауз ([DarkRunTiming]), то есть правило подтверждения
/// выключения получает числа от записи, а не от догадки.
class ModeComparator {
  const ModeComparator();

  /// Способ решения по цветовым долям — прежний живой отсчёт.
  static LampConfig legacy(LampConfig base) =>
      base.copyWith(liveReference: true, spatialVectors: false);

  /// Способ решения по яркости четырёх областей — тоже живой, поэтому калибровка
  /// для сравнения не нужна ни одному из них.
  static LampConfig spatial(LampConfig base) =>
      base.copyWith(liveReference: true, spatialVectors: true);

  static ModeComparison compare(String csv, {LampConfig base = const LampConfig()}) {
    final List<FeatureCsvRow> rows = FeatureCsv.decode(csv);
    if (rows.length < 2) {
      throw ArgumentError('для сравнения нужно минимум два кадра записи');
    }

    final _Run legacyRun = _replay(rows, legacy(base));
    final _Run spatialRun = _replay(rows, spatial(base));
    final _Timing timing = _measureTiming(rows, base);

    final List<int> deltas = <int>[];
    for (int i = 1; i < rows.length; i++) {
      deltas.add(rows[i].timestampMs - rows[i - 1].timestampMs);
    }
    deltas.sort();

    final List<String> mismatches = <String>[];
    for (final int t in <int>{...legacyRun.eventMs, ...spatialRun.eventMs}) {
      final bool inLegacy = legacyRun.eventMs.contains(t);
      final bool inSpatial = spatialRun.eventMs.contains(t);
      if (inLegacy == inSpatial) {
        continue;
      }
      mismatches.add('$t мс ${inLegacy ? 'только цвет' : 'только яркость'}');
      if (mismatches.length >= 8) {
        break;
      }
    }

    return ModeComparison(
      frames: rows.length,
      span: Duration(
        milliseconds: rows.last.timestampMs - rows.first.timestampMs,
      ),
      medianFrameMs: deltas[deltas.length ~/ 2],
      legacyWhiteEvents: legacyRun.white,
      legacyRedEvents: legacyRun.red,
      spatialWhiteEvents: spatialRun.white,
      spatialRedEvents: spatialRun.red,
      mismatches: mismatches,
      whiteTiming: timing.white,
      redTiming: timing.red,
      offConfirmMs: base.offConfirmMs,
    );
  }

  /// Считает провалы и паузы по решениям детектора, идя по записи в точности
  /// так, как на живом стенде.
  static _Timing _measureTiming(List<FeatureCsvRow> rows, LampConfig cfg) {
    final LampDetector detector = LampDetector(cfg);
    final _Tracker white = _Tracker();
    final _Tracker red = _Tracker();
    for (final FeatureCsvRow row in rows) {
      final LampFrame frame = row.toLampFrame();
      final LampEvaluation e = detector.evaluate(frame);
      final double level = detector.whiteOnLevel ?? 0;
      white.step(darkMs: e.whiteDarkMs, on: e.whiteOn, off: e.whiteOff, lit: e.whiteLit, back: e.whiteAmplitude >= level);
      red.step(
        darkMs: e.redDarkMs,
        on: e.redOn,
        off: e.redOff,
        lit: e.redLit,
        back: e.redAmplitude >= (detector.redOnLevel ?? 0),
      );
    }
    return _Timing(
      white: white.done('белая'),
      red: red.done('красная'),
    );
  }

  /// Один прогон записи выбранным способом: сколько событий и в какие моменты.
  static _Run _replay(List<FeatureCsvRow> rows, LampConfig cfg) {
    final LampDetector detector = LampDetector(cfg);
    final HitStateMachine machine = HitStateMachine(sessionId: 'compare');
    final Set<int> events = <int>{};
    int white = 0;
    int red = 0;
    for (final FeatureCsvRow row in rows) {
      for (final HitEvent event in machine.onEvaluation(detector.evaluate(row.toLampFrame()))) {
        if (event.color == HitColor.white) {
          white++;
        } else {
          red++;
        }
        // Событие датировано кадром-кандидатом, а не кадром подтверждения: по
        // нему и надо сравнивать способы, иначе их расхождение превратится в
        // сдвиг на два кадра.
        events.add(event.detectedAt.millisecondsSinceEpoch);
      }
    }
    return _Run(white: white, red: red, eventMs: events);
  }
}

class _Run {
  const _Run({required this.white, required this.red, required this.eventMs});
  final int white;
  final int red;
  final Set<int> eventMs;
}

class _Timing {
  const _Timing({required this.white, required this.red});
  final DarkRunTiming white;
  final DarkRunTiming red;
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
