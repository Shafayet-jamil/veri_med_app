import 'dart:math' as math;
import 'package:flutter/material.dart';

class VerificationBadge extends StatelessWidget {
  const VerificationBadge({super.key, required this.verification});

  final Map<String, dynamic> verification;

  @override
  Widget build(BuildContext context) {
    final score = (verification['verification_score'] as num?)?.toInt() ?? 0;
    final verdict = verification['verdict']?.toString() ?? 'unknown';
    final verdictLabel = verification['verdict_label']?.toString() ?? 'Unknown';
    final verdictDesc =
        verification['verdict_description']?.toString() ?? '';
    final checks = (verification['checks'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final matchedFields = (verification['matched_fields'] as num?)?.toInt() ?? 0;
    final mismatchedFields =
        (verification['mismatched_fields'] as num?)?.toInt() ?? 0;
    final totalFields = (verification['total_fields'] as num?)?.toInt() ?? 0;
    final readFields =
        (verification['read_fields'] as num?)?.toInt() ?? totalFields;
    final notVisibleFields = totalFields - readFields;
    // A percentage is only meaningful when at least two details were read;
    // "100%" from a single readable detail would overstate the check.
    final showScore = readFields >= 2;

    final color = _verdictColor(verdict);
    final icon = _verdictIcon(verdict);

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Authenticity Verification',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (!showScore)
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 48),
                ),
              )
            else ...[
            Center(
              child: SizedBox(
                width: 140,
                height: 140,
                child: CustomPaint(
                  painter: _ScoreGaugePainter(
                    score: score / 100.0,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.12),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: color, size: 28),
                        const SizedBox(height: 4),
                        Text(
                          '$score%',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'of the readable details match',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            ],
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  verdictLabel,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                verdictDesc,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            if (checks.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F8F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Field comparison',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '$matchedFields match',
                        if (mismatchedFields > 0) '$mismatchedFields differ',
                        if (notVisibleFields > 0)
                          '$notVisibleFields not visible in photo',
                      ].join(' · '),
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    for (final check in checks) ...[
                      _buildCheckRow(context, check),
                      if (check != checks.last)
                        const Divider(height: 16),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCheckRow(BuildContext context, Map<String, dynamic> check) {
    final field = check['field']?.toString() ?? '';
    final extracted = check['extracted']?.toString() ?? '';
    final registered = check['registered']?.toString() ?? '';
    final status = check['status']?.toString() ??
        (check['match'] == true ? 'match' : 'mismatch');
    final (statusIcon, statusColor) = switch (status) {
      'match' => (Icons.check_circle, const Color(0xFF388E3C)),
      'mismatch' => (Icons.cancel, const Color(0xFFD32F2F)),
      _ => (Icons.visibility_off_outlined, const Color(0xFF9E9E9E)),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(statusIcon, color: statusColor, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                switch (status) {
                  'match' => field,
                  'mismatch' => '$field: does not match',
                  _ => '$field: not visible in photo',
                },
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: status == 'mismatch' ? statusColor : null,
                ),
              ),
              const SizedBox(height: 2),
              RichText(
                text: TextSpan(
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  children: [
                    const TextSpan(
                        text: 'Package: ',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    TextSpan(text: extracted),
                  ],
                ),
              ),
              RichText(
                text: TextSpan(
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  children: [
                    const TextSpan(
                        text: 'DGDA: ',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    TextSpan(text: registered),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _verdictColor(String verdict) {
    switch (verdict) {
      case 'likely_genuine':
        return const Color(0xFF2E7D32);
      case 'partial_match':
        return const Color(0xFF00796B);
      case 'manufacturer_only':
        return const Color(0xFF1565C0);
      case 'suspicious':
        return const Color(0xFFF57C00);
      case 'likely_counterfeit':
        return const Color(0xFFC62828);
      case 'no_record':
        return const Color(0xFF6D4C41);
      default:
        return const Color(0xFF757575);
    }
  }

  IconData _verdictIcon(String verdict) {
    switch (verdict) {
      case 'likely_genuine':
        return Icons.verified;
      case 'partial_match':
        return Icons.fact_check_outlined;
      case 'manufacturer_only':
        return Icons.factory_outlined;
      case 'suspicious':
        return Icons.warning_amber;
      case 'likely_counterfeit':
        return Icons.gpp_bad;
      case 'no_record':
        return Icons.search_off;
      default:
        return Icons.help_outline;
    }
  }
}

class _ScoreGaugePainter extends CustomPainter {
  _ScoreGaugePainter({
    required this.score,
    required this.color,
    required this.backgroundColor,
  });

  final double score;
  final Color color;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    const strokeWidth = 10.0;
    const startAngle = -math.pi * 0.75;
    const sweepFull = math.pi * 1.5;

    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepFull,
      false,
      bgPaint,
    );

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepFull * score.clamp(0.0, 1.0),
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(_ScoreGaugePainter oldDelegate) =>
      oldDelegate.score != score || oldDelegate.color != color;
}
