import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'technical_summary.dart';

/// Semicircle "technicals" gauge in the style of the user's reference
/// screenshot: five arcs Strong sell -> Strong buy (red to blue through
/// grey) on a dark card, a needle at the current score and the rating
/// label under it. Pure presentation - all data comes from the caller.
class TechnicalGauge extends StatelessWidget {
  final TechRating rating;

  /// Mean vote in [-1, 1]; positions the needle.
  final double score;
  final double width;

  const TechnicalGauge({
    super.key,
    required this.rating,
    required this.score,
    this.width = 240,
  });

  static const segmentColors = <Color>[
    Color(0xFFE53935), // strong sell
    Color(0xFFF0857D), // sell
    Color(0xFF9E9E9E), // neutral
    Color(0xFF7EA8F8), // buy
    Color(0xFF1E88E5), // strong buy
  ];

  static const ratingColors = <TechRating, Color>{
    TechRating.strongSell: Color(0xFFE53935),
    TechRating.sell: Color(0xFFF0857D),
    TechRating.neutral: Color(0xFF9E9E9E),
    TechRating.buy: Color(0xFF7EA8F8),
    TechRating.strongBuy: Color(0xFF1E88E5),
  };

  @override
  Widget build(BuildContext context) {
    final height = width * 0.62;
    return SizedBox(
      width: width,
      height: height + 30,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          CustomPaint(
            size: Size(width, height),
            painter: _GaugePainter(score: score.clamp(-1.0, 1.0).toDouble()),
          ),
          Positioned(
            bottom: 0,
            child: Text(
              techRatingLabel(rating),
              style: TextStyle(
                color: ratingColors[rating],
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double score;
  _GaugePainter({required this.score});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final radius = size.width / 2 - 8;
    const gap = 0.035; // radians between segments
    const sweep = math.pi / 5;
    for (int i = 0; i < 5; i++) {
      final paint = Paint()
        ..color = TechnicalGauge.segmentColors[i]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        math.pi + i * sweep + gap,
        sweep - 2 * gap,
        false,
        paint,
      );
    }
    // Needle: score -1 -> 180deg (left), +1 -> 0deg (right).
    final angle = math.pi * (1 - (score + 1) / 2);
    final tip = Offset(
      center.dx + radius * 0.82 * math.cos(angle),
      center.dy - radius * 0.82 * math.sin(angle),
    );
    final needle = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, needle);
    canvas.drawCircle(center, 7, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.score != score;
}
