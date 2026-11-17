import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// Панель метрик: без неё невозможно понять, где теряются события.
class DiagnosticsPanel extends StatelessWidget {
  const DiagnosticsPanel({
    super.key,
    required this.session,
    required this.message,
    required this.dataDirectory,
  });

  final DetectionSession session;
  final String message;
  final String dataDirectory;

  @override
  Widget build(BuildContext context) {
    final DiagnosticsSnapshot d = session.diagnostics.snapshot;
    final LampConfig c = session.config;
    final LampStatus s = session.status;
    final LampBaseline? b = session.baseline;

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      children: <Widget>[
        if (d.needsIsolate)
          _warn(
            'Среднее время анализа ${d.avgAnalysisMs.toStringAsFixed(1)} мс > '
            '${c.analysisIsolateThresholdMs} мс — выносить в isolate',
          ),
        if (d.droppedFrames > 0)
          _warn(
            'Пропущено кадров: ${d.droppedFrames} — возможен пропуск короткой вспышки',
          ),
        _section('Кадр и анализ'),
        _row('FPS камеры', d.cameraFps.toStringAsFixed(1)),
        _row('FPS анализа', d.analysisFps.toStringAsFixed(1)),
        _row('Анализ, среднее (мс)', d.avgAnalysisMs.toStringAsFixed(2)),
        _row('Анализ, макс (мс)', d.maxAnalysisMs.toStringAsFixed(2)),
        _row('Кадров обработано', '${d.framesProcessed}'),
        _row('droppedFrames', '${d.droppedFrames}'),
        _section('Экспозиция (проверка авто)'),
        _row(
          'sensorExposureTime, мс',
          d.exposureTimeNs == null
              ? 'н/д'
              : (d.exposureTimeNs! / 1000000).toStringAsFixed(2),
        ),
        _row('ISO', d.sensorSensitivity?.toStringAsFixed(0) ?? 'н/д'),
        _section('События'),
        _row('Событий', '${d.eventCount}'),
        _row('Неоднозначных кадров', '${d.ambiguousFrames}'),
        _row(
          'Обнаружение → SQLite, среднее (мс)',
          d.avgSaveLatencyMs.toStringAsFixed(2),
        ),
        _row(
          'Обнаружение → SQLite, макс (мс)',
          d.maxSaveLatencyMs.toStringAsFixed(2),
        ),
        _section('Пороги'),
        _row(
          'white: minChannel',
          c.whiteMinChannel.toStringAsFixed(0),
        ),
        _row(
          'red: margin / minValue',
          '${c.redMargin.toStringAsFixed(0)} / ${c.redMinValue.toStringAsFixed(0)}',
        ),
        _row(
          'white ON / OFF',
          '${c.whiteOnThreshold} / ${c.whiteOffThreshold.toStringAsFixed(3)}',
        ),
        _row(
          'red ON / OFF',
          '${c.redOnThreshold} / ${c.redOffThreshold.toStringAsFixed(3)}',
        ),
        _row(
          'подтверждение ON / OFF',
          '${c.onConfirmFrames} / ${c.offConfirmFrames} кадров',
        ),
        _row('подвыборка', 'каждый ${c.subsampleStep}-й пиксель'),
        _row('yuvFullRange', '${c.yuvFullRange}'),
        _section('Калибровка'),
        _row(
          'baseline белой Y',
          b == null ? 'нет' : b.white.meanY.toStringAsFixed(1),
        ),
        _row('baseline белой whiteFrac / σ',
            b == null ? 'нет' : '${b.white.whiteFrac.toStringAsFixed(3)} / ${b.whiteNoise.toStringAsFixed(3)}'),
        _row('baseline красной redFrac / σ',
            b == null ? 'нет' : '${b.red.redFrac.toStringAsFixed(3)} / ${b.redNoise.toStringAsFixed(3)}'),
        _row(
          'baseline красной Y',
          b == null ? 'нет' : b.red.meanY.toStringAsFixed(1),
        ),
        _row(
          'baseline красной redDom',
          b == null ? 'нет' : b.red.redDom.toStringAsFixed(1),
        ),
        _row(
          'baseline красной coreEdge',
          b == null ? 'нет' : b.red.coreEdgeDiff.toStringAsFixed(1),
        ),
        _section('Данные'),
        _row('ROI белой', '${session.roi.white}'),
        _row('ROI красной', '${session.roi.red}'),
        _row('session', s.sessionId),
        _row('CSV', s.csvPath ?? 'не пишется'),
        _row('каталог', dataDirectory),
        _section('Последнее сообщение'),
        Text(message, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  static Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        color: Colors.teal,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  static Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
      ],
    ),
  );

  static Widget _warn(String text) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.all(6),
    color: const Color(0x33FFB300),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xFFFFB300)),
    ),
  );
}
