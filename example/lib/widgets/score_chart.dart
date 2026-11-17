import 'package:flutter/material.dart';
import 'package:lamp_detection/lamp_detection.dart';

/// График whiteScore и redScore по времени, нормированных на их ON-порог.
///
/// Линия y=1 — порог включения. Режим «повторное попадание»: по этому графику
/// видно, меняется ли что-то при повторном ударе, пока лампа ещё горит.
class ScoreChart extends StatelessWidget {
  const ScoreChart({super.key, required this.session});

  final DetectionSession session;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ScorePainter(
        points: session.scoreHistory,
        whiteThreshold: session.config.whiteOnThreshold,
        redThreshold: session.config.redOnThreshold,
      ),
      size: Size.infinite,
      child: const ColoredBox(color: Color(0xFF14161A)),
    );
  }
}

class _ScorePainter extends CustomPainter {
  _ScorePainter({
    required this.points,
    required this.whiteThreshold,
    required this.redThreshold,
  });

  final List<ScorePoint> points;
  final double whiteThreshold;
  final double redThreshold;

  static const double _maxVisibleRatio = 3;
  static const double _thresholdRatio = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final TextPainter caption = TextPainter(
      text: const TextSpan(
        text: 'score / ON-порог (1.0 = порог)',
        style: TextStyle(color: Colors.grey, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    caption.paint(canvas, const Offset(4, 2));

    final double maxY = _maxVisibleRatio;
    double toY(double ratio) => size.height - (ratio / maxY).clamp(0.0, 1.0) * size.height;

    // Линия порога.
    canvas.drawLine(
      Offset(0, toY(_thresholdRatio)),
      Offset(size.width, toY(_thresholdRatio)),
      Paint()
        ..color = Colors.grey.withValues(alpha: 0.6)
        ..strokeWidth = 1,
    );

    if (points.length < 2) {
      return;
    }
    final double step = size.width / (points.length - 1);
    _paintSeries(
      canvas,
      step,
      (int i) => points[i].white / whiteThreshold,
      toY,
      Colors.white,
    );
    _paintSeries(
      canvas,
      step,
      (int i) => points[i].red / redThreshold,
      toY,
      Colors.redAccent,
    );
  }

  void _paintSeries(
    Canvas canvas,
    double step,
    double Function(int index) ratioAt,
    double Function(double ratio) toY,
    Color color,
  ) {
    final Path path = Path();
    for (int i = 0; i < points.length; i++) {
      final Offset point = Offset(i * step, toY(ratioAt(i)));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_ScorePainter oldDelegate) =>
      oldDelegate.points.length != points.length ||
      (points.isNotEmpty &&
          oldDelegate.points.isNotEmpty &&
          oldDelegate.points.last.at != points.last.at);
}
