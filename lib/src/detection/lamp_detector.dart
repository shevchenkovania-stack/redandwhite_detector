import '../models/frame_features.dart';
import '../models/hit_event.dart';
import '../models/lamp_config.dart';

/// Результат оценки одного кадра детектором.
class LampEvaluation {
  const LampEvaluation({
    required this.timestamp,
    required this.whiteScore,
    required this.redScore,
    required this.whiteOn,
    required this.redOn,
    required this.whiteOff,
    required this.redOff,
    required this.whiteLit,
    required this.redLit,
    required this.ambiguous,
    required this.ambiguousWinner,
    required this.whiteOnCandidateAt,
    required this.redOnCandidateAt,
  });

  final DateTime timestamp;
  final double whiteScore;
  final double redScore;

  /// Подтверждённое включение (N подряд кадров выше ON-порога) этим кадром.
  final bool whiteOn;
  final bool redOn;

  /// Подтверждённое выключение (M подряд кадров ниже OFF-порога) этим кадром.
  final bool whiteOff;
  final bool redOff;

  /// Текущее состояние гистерезиса каждой лампы.
  final bool whiteLit;
  final bool redLit;

  /// Кадр, в котором обе лампы выше ON-порога одновременно.
  final bool ambiguous;
  final HitColor? ambiguousWinner;

  /// Время кадра, где лампа впервые стала кандидатом ON в текущей серии.
  /// Именно оно попадает в HitEvent.detectedAt.
  final DateTime? whiteOnCandidateAt;
  final DateTime? redOnCandidateAt;
}

/// Гистерезис одной лампы: подтверждение включения/выключения.
class _LampTracker {
  bool lit = false;
  int _onRun = 0;
  int _offRun = 0;
  DateTime? _onCandidateAt;

  /// Возвращает [becameOn]/[becameOff] — подтверждённые переходы этим кадром.
  ({bool becameOn, bool becameOff}) step({
    required bool aboveOn,
    required bool belowOff,
    required DateTime timestamp,
    required int onConfirmFrames,
    required int offConfirmFrames,
  }) {
    if (aboveOn) {
      _onRun++;
      _offRun = 0;
      _onCandidateAt ??= timestamp;
    } else if (belowOff) {
      _offRun++;
      _onRun = 0;
      _onCandidateAt = null;
    } else {
      // Гистерезисная зона: neither ON nor OFF, серия сбрасывается.
      _onRun = 0;
      _offRun = 0;
      _onCandidateAt = null;
    }

    bool becameOn = false;
    bool becameOff = false;
    if (!lit && _onRun >= onConfirmFrames) {
      lit = true;
      becameOn = true;
    } else if (lit && _offRun >= offConfirmFrames) {
      lit = false;
      becameOff = true;
    }
    return (becameOn: becameOn, becameOff: becameOff);
  }

  DateTime? get onCandidate => _onCandidateAt;

  void reset() {
    lit = false;
    _onRun = 0;
    _offRun = 0;
    _onCandidateAt = null;
  }
}

/// Оценка «включена ли лампа» по признакам относительно baseline и автомат
/// гистерезиса на обе лампы.
///
/// Точность зависит от порогов, которые подбираются на реальных записях; здесь
/// только детерминированная арифметика из [LampConfig].
class LampDetector {
  LampDetector(this.config);

  /// Пороги можно менять на лету (подбор по записанным CSV).
  LampConfig config;

  final _LampTracker _white = _LampTracker();
  final _LampTracker _red = _LampTracker();
  final List<FrameFeatures> _calibrationWhite = <FrameFeatures>[];
  final List<FrameFeatures> _calibrationRed = <FrameFeatures>[];

  LampBaseline? _baseline;
  int _ambiguousFrames = 0;

  LampBaseline? get baseline => _baseline;
  bool get isCalibrated => _baseline?.isCalibrated ?? false;

  /// Сколько кадров подряд были неоднозначными (обе лампы выше ON-порога).
  int get ambiguousFrames => _ambiguousFrames;

  /// Восстановление baseline из настроек.
  void setBaseline(LampBaseline baseline) {
    _baseline = baseline;
    resetTracking();
  }

  /// Сброс гистерезиса и счётчиков (новая сессия, старт, калибровка).
  void resetTracking() {
    _white.reset();
    _red.reset();
    _ambiguousFrames = 0;
  }

  /// Прогресс калибровки «обе выключены».
  CalibrationProgress get calibrationProgress => CalibrationProgress(
    collected: _calibrationWhite.length,
    needed: config.calibrationFrames,
  );

  void clearCalibration() {
    _calibrationWhite.clear();
    _calibrationRed.clear();
  }

  /// Добавляет кадр в калибровку. Возвращает готовый baseline, когда набрано
  /// [LampConfig.calibrationFrames] кадров, иначе null.
  LampBaseline? addCalibrationFrame(LampFrame frame) {
    _calibrationWhite.add(frame.white);
    _calibrationRed.add(frame.red);
    if (_calibrationWhite.length < config.calibrationFrames) {
      return null;
    }
    final LampBaseline baseline = LampBaseline(
      white: _average(_calibrationWhite),
      red: _average(_calibrationRed),
      frameCount: _calibrationWhite.length,
    );
    clearCalibration();
    _baseline = baseline;
    resetTracking();
    return baseline;
  }

  static FrameFeatures _average(List<FrameFeatures> features) {
    double meanY = 0;
    double brightFrac = 0;
    double sat = 0;
    double redDom = 0;
    double coreEdgeDiff = 0;
    int samples = 0;
    for (final FrameFeatures f in features) {
      meanY += f.meanY;
      brightFrac += f.brightFrac;
      sat += f.sat;
      redDom += f.redDom;
      coreEdgeDiff += f.coreEdgeDiff;
      samples += f.sampleCount;
    }
    final int n = features.length;
    return FrameFeatures(
      meanY: meanY / n,
      brightFrac: brightFrac / n,
      sat: sat / n,
      redDom: redDom / n,
      coreEdgeDiff: coreEdgeDiff / n,
      sampleCount: n == 0 ? 0 : (samples / n).round(),
    );
  }

  /// whiteScore = brightFrac, но 0, если насыщенность выше порога: красная
  /// подсветка сцены не должна считаться белой лампой.
  double whiteScore(FrameFeatures white) =>
      white.sat <= config.whiteSatMax ? white.brightFrac : 0;

  /// redScore = рост **красноты** (`redDom`) относительно baseline. Красная
  /// вспышка почти не меняет общую яркость (красный даёт мало в BT.601), но резко
  /// поднимает `redDom = mean(R) − mean((G+B)/2)`. Белая вспышка, наоборот,
  /// выравнивает каналы → `redDom` не растёт, поэтому красная рамка на белую
  /// вспышку не срабатывает. Ядро/кольцо (`coreEdgeDiff`) намеренно НЕ участвует:
  /// при ходу камеры центр рамки всегда разный, и это лишь шумит.
  double redScore(FrameFeatures red, LampBaseline baseline) =>
      (red.redDom - baseline.red.redDom) / config.redDeltaDivisor;

  LampEvaluation evaluate(LampFrame frame) {
    final LampBaseline? baseline = _baseline;
    if (baseline == null || !baseline.isCalibrated) {
      throw StateError(
        'Детектор не откалиброван: сначала калибровка «обе выключены»',
      );
    }

    final double white = whiteScore(frame.white);
    final double red = redScore(frame.red, baseline);

    bool whiteAboveOn = white >= config.whiteOnThreshold;
    bool redAboveOn = red >= config.redOnThreshold;
    final bool whiteBelowOff = white < config.whiteOffThreshold;
    final bool redBelowOff = red < config.redOffThreshold;

    // Обе лампы выше ON-порога в одном кадре: побеждает бо́льший score/порог,
    // проигравший в этом кадре не считается ни ON, ни OFF (нейтральная зона),
    // чтобы не подтвердить событие по неоднозначному кадру.
    bool ambiguous = false;
    HitColor? winner;
    if (whiteAboveOn && redAboveOn) {
      ambiguous = true;
      _ambiguousFrames++;
      final bool whiteWins =
          white / config.whiteOnThreshold >= red / config.redOnThreshold;
      winner = whiteWins ? HitColor.white : HitColor.red;
      if (whiteWins) {
        redAboveOn = false;
      } else {
        whiteAboveOn = false;
      }
    }

    final ({bool becameOn, bool becameOff}) whiteStep = _white.step(
      aboveOn: whiteAboveOn,
      belowOff: whiteBelowOff,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
    );
    final ({bool becameOn, bool becameOff}) redStep = _red.step(
      aboveOn: redAboveOn,
      belowOff: redBelowOff,
      timestamp: frame.timestamp,
      onConfirmFrames: config.onConfirmFrames,
      offConfirmFrames: config.offConfirmFrames,
    );

    // Скользящее среднее baseline — только когда обе лампы погаснуты: ни одна
    // не подтверждена как горящая и ни одна не превысила ON-порог (иначе кадр
    // со включением лампы успел бы сдвинуть baseline до подтверждения).
    final bool bothDark =
        !_white.lit &&
        !_red.lit &&
        !whiteAboveOn &&
        !redAboveOn &&
        _white.onCandidate == null &&
        _red.onCandidate == null;
    if (bothDark) {
      _baseline = _blend(baseline, frame);
    }

    return LampEvaluation(
      timestamp: frame.timestamp,
      whiteScore: white,
      redScore: red,
      whiteOn: whiteStep.becameOn,
      redOn: redStep.becameOn,
      whiteOff: whiteStep.becameOff,
      redOff: redStep.becameOff,
      whiteLit: _white.lit,
      redLit: _red.lit,
      ambiguous: ambiguous,
      ambiguousWinner: winner,
      whiteOnCandidateAt: _white.onCandidate,
      redOnCandidateAt: _red.onCandidate,
    );
  }

  LampBaseline _blend(LampBaseline baseline, LampFrame frame) {
    final double alpha = config.baselineAlpha;
    return LampBaseline(
      white: _blendFeatures(baseline.white, frame.white, alpha),
      red: _blendFeatures(baseline.red, frame.red, alpha),
      frameCount: baseline.frameCount,
    );
  }

  static FrameFeatures _blendFeatures(
    FrameFeatures base,
    FrameFeatures now,
    double alpha,
  ) => FrameFeatures(
    meanY: base.meanY + (now.meanY - base.meanY) * alpha,
    brightFrac: base.brightFrac + (now.brightFrac - base.brightFrac) * alpha,
    sat: base.sat + (now.sat - base.sat) * alpha,
    redDom: base.redDom + (now.redDom - base.redDom) * alpha,
    coreEdgeDiff:
        base.coreEdgeDiff + (now.coreEdgeDiff - base.coreEdgeDiff) * alpha,
    sampleCount: now.sampleCount,
  );
}

/// Прогресс набора кадров для калибровки.
class CalibrationProgress {
  const CalibrationProgress({required this.collected, required this.needed});

  final int collected;
  final int needed;

  bool get isComplete => collected >= needed;
  int get remaining => (needed - collected).clamp(0, needed);

  @override
  String toString() => 'Калибровка: $collected/$needed';
}
