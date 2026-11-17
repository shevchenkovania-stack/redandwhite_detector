import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Живая «расшифровка»: какие числа видит детектор прямо сейчас и как из них
/// получается whiteScore / redScore. Плюс сравнение параметров с дефолтом.
class DecoderSheet extends StatefulWidget {
  const DecoderSheet({required this.session, super.key});

  final DetectionSession session;

  @override
  State<DecoderSheet> createState() => _DecoderSheetState();
}

class _DecoderSheetState extends State<DecoderSheet> {
  @override
  void initState() {
    super.initState();
    widget.session.frameTick.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.session.frameTick.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) {
      setState(() {});
    }
  }

  static String _f(double v, [int digits = 1]) => v.toStringAsFixed(digits);

  @override
  Widget build(BuildContext context) {
    final DetectionSession s = widget.session;
    final LampFrame? features = s.lastFeatures;
    final LampEvaluation? eval = s.lastEvaluation;
    final LampBaseline? base = s.baseline;
    final LampConfig cfg = s.config;
    const LampConfig def = LampConfig();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        if (features == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Нет кадра. Нажми «Пуск» — расшифровка появится сама.'),
          ),
        if (features != null) ...<Widget>[
          _lampBlock(
            title: 'БЕЛАЯ рамка',
            lit: eval?.whiteLit ?? false,
            color: Colors.white,
            score: eval?.whiteScore,
            scoreFormula: 'whiteScore = whiteFrac − фон  (пиксель белый, если min(R,G,B) ≥ ${_f(cfg.whiteMinChannel, 0)})',
            onThreshold: cfg.whiteOnThreshold,
            offThreshold: cfg.whiteOffThreshold,
            now: features.white,
            background: base?.white,
            driving: 'whiteFrac',
          ),
          const SizedBox(height: 12),
          _lampBlock(
            title: 'КРАСНАЯ рамка',
            lit: eval?.redLit ?? false,
            color: Colors.redAccent,
            score: eval?.redScore,
            scoreFormula:
                'redScore = (redFrac − фон) / ${_f(cfg.redFracDivisor, 3)}  (R − max(G,B) ≥ ${_f(cfg.redMargin, 0)})',
            onThreshold: cfg.redOnThreshold,
            offThreshold: cfg.redOffThreshold,
            now: features.red,
            background: base?.red,
            driving: 'redFrac',
          ),
          if (eval != null && eval.ambiguous)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Неоднозначный кадр: обе выше ON, побеждает ${eval.ambiguousWinner?.name}',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
          const SizedBox(height: 18),
          _paramsHeader(),
          const SizedBox(height: 6),
          _paramRow('brightY (порог «яркий»)', cfg.brightY, def.brightY),
          _paramRow('whiteMinChannel', cfg.whiteMinChannel, def.whiteMinChannel),
          _paramRow('redMargin', cfg.redMargin, def.redMargin),
          _paramRow('redMinValue', cfg.redMinValue, def.redMinValue),
          _paramRow('redFracDivisor', cfg.redFracDivisor, def.redFracDivisor),
          _paramRow('noiseSigmas', cfg.noiseSigmas, def.noiseSigmas),
          _paramRow('whiteOnThreshold', cfg.whiteOnThreshold, def.whiteOnThreshold),
          _paramRow('redOnThreshold', cfg.redOnThreshold, def.redOnThreshold),
          _paramRow('offRatio (гистерезис)', cfg.offRatio, def.offRatio),
          _paramRow('onConfirmFrames', cfg.onConfirmFrames, def.onConfirmFrames),
          _paramRow('offConfirmFrames', cfg.offConfirmFrames, def.offConfirmFrames),
          _paramRow('calibrationFrames', cfg.calibrationFrames, def.calibrationFrames),
          _paramRow('subsampleStep', cfg.subsampleStep, def.subsampleStep),
          if (base == null)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('Калибровки нет — детектор не работает до калибровки.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
        ],
      ],
    );
  }

  Widget _lampBlock({
    required String title,
    required bool lit,
    required Color color,
    required double? score,
    required String scoreFormula,
    required double onThreshold,
    required double offThreshold,
    required FrameFeatures now,
    FrameFeatures? background,
    required String driving,
  }) {
    final bool aboveOn = score != null && score >= onThreshold;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: lit ? color : Colors.grey.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.circle, size: 12, color: lit ? color : Colors.grey),
              const SizedBox(width: 6),
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: lit ? color : Colors.grey)),
              const Spacer(),
              Text(lit ? 'ГОРИТ' : 'погашена',
                  style: TextStyle(fontSize: 12, color: lit ? color : Colors.grey)),
            ],
          ),
          const SizedBox(height: 6),
          Text(scoreFormula,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(
            score == null
                ? 'score: — (не откалиброван)'
                : 'score: ${_f(score, 2)}   →   ${aboveOn ? 'ВЫШЕ ON' : 'ниже ON'} '
                    '(ON ${_f(onThreshold, 2)} / OFF ${_f(offThreshold, 2)})',
            style: TextStyle(
                fontSize: 12, color: aboveOn ? color : Colors.white70),
          ),
          const SizedBox(height: 6),
          _featureHeader(),
          _featureRow('whiteFrac', now.whiteFrac, background?.whiteFrac, 3, driving),
          _featureRow('redFrac', now.redFrac, background?.redFrac, 3, driving),
          _featureRow('meanY', now.meanY, background?.meanY, 1, driving),
          _featureRow('brightFrac', now.brightFrac, background?.brightFrac, 2, driving),
          _featureRow('sat', now.sat, background?.sat, 2, driving),
          _featureRow('redDom', now.redDom, background?.redDom, 1, driving),
          _featureRow('coreEdgeDiff', now.coreEdgeDiff, background?.coreEdgeDiff, 1, driving),
        ],
      ),
    );
  }

  Widget _featureHeader() => const Padding(
        padding: EdgeInsets.only(bottom: 2),
        child: Row(
          children: <Widget>[
            SizedBox(width: 120, child: Text('признак', style: TextStyle(fontSize: 10, color: Colors.grey))),
            Expanded(child: Text('сейчас', style: TextStyle(fontSize: 10, color: Colors.grey))),
            Expanded(child: Text('фон', style: TextStyle(fontSize: 10, color: Colors.grey))),
          ],
        ),
      );

  Widget _featureRow(String name, double now, double? base, int digits, String driving) {
    final bool isDriver = name == driving;
    final TextStyle style = TextStyle(
      fontSize: 12,
      color: isDriver ? Colors.amberAccent : Colors.white,
      fontWeight: isDriver ? FontWeight.bold : FontWeight.normal,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: <Widget>[
          SizedBox(width: 120, child: Text(name, style: style)),
          Expanded(child: Text(_f(now, digits), style: style)),
          Expanded(
            child: Text(base == null ? '—' : _f(base, digits),
                style: style.copyWith(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _paramsHeader() => const Text(
        'Параметры (сейчас · дефолт)',
        style: TextStyle(fontWeight: FontWeight.bold),
      );

  Widget _paramRow(String label, Object current, Object defaultValue) {
    final bool changed = current.toString() != defaultValue.toString();
    final Color c = changed ? Colors.amberAccent : Colors.white70;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: c))),
          Text('$current', style: TextStyle(fontSize: 12, color: c)),
          const SizedBox(width: 8),
          Text('(def $defaultValue)',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }
}
