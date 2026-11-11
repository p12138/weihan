import 'package:flutter/material.dart';

/// 应用标识：与桌面图标、启动页同源的「交织双环 + 中心星芒」。
///
/// 几何对齐 `brand/app-icon.svg`：两条圆角带子各转 ±42° 互相穿插，中央一枚
/// 四角星。颜色默认取品牌固定色，和桌面图标 / 启动页保持一致，不随主题漂移 ——
/// 品牌标识应当稳定，主题换的是界面不是 logo。三个可选参数保留给需要换色的
/// 场景，调用方全部用默认值时仍是 const 构造。
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 36,
    this.bubble,
    this.accent,
    this.ink,
  });

  /// 标识整体边长（正方形）。
  final double size;

  /// 中心星芒颜色，默认暖白 `#FFF6D8`。
  final Color? bubble;

  /// 青绿环的亮端，默认 `#57DCC3`。
  final Color? accent;

  /// 琥珀环的亮端，默认 `#FFB36B`。
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BrandMarkPainter(
          star: bubble ?? const Color(0xFFFFF6D8),
          teal: accent ?? const Color(0xFF57DCC3),
          amber: ink ?? const Color(0xFFFFB36B),
        ),
      ),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter({
    required this.star,
    required this.teal,
    required this.amber,
  });

  final Color star;
  final Color teal;
  final Color amber;

  /// 两条带子先按「琥珀在下、青绿在上」叠放，再在左半屏把琥珀带补画一次，
  /// 左右两个交叉点就有了不同的前后关系 —— 这就是「交织」而不是「叠放」。
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final Rect bounds = Rect.fromCenter(center: center, width: s, height: s);

    final Path amberRing = _rotatedRing(center, s * 0.74, s * 0.38, -0.72);
    final Path tealRing = _rotatedRing(center, s * 0.74, s * 0.38, 0.72);

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.145
      ..strokeCap = StrokeCap.round;

    final Shader amberShader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[
        amber,
        Color.lerp(amber, const Color(0xFFFFE9B6), 0.6) ?? amber,
      ],
    ).createShader(bounds);
    final Shader tealShader = LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: <Color>[
        Color.lerp(teal, const Color(0xFF17979C), 0.55) ?? teal,
        teal,
      ],
    ).createShader(bounds);

    canvas.drawPath(amberRing, stroke..shader = amberShader);
    canvas.drawPath(tealRing, stroke..shader = tealShader);

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width / 2, size.height));
    canvas.drawPath(amberRing, stroke..shader = amberShader);
    canvas.restore();

    // 中心四角星：四条二次贝塞尔把尖端之间的边往内收，形成细长的星芒。
    final double r = s * 0.145;
    final double waist = r * 0.14;
    final Path starPath = Path()
      ..moveTo(center.dx, center.dy - r)
      ..quadraticBezierTo(center.dx + waist, center.dy - waist,
          center.dx + r, center.dy)
      ..quadraticBezierTo(center.dx + waist, center.dy + waist,
          center.dx, center.dy + r)
      ..quadraticBezierTo(center.dx - waist, center.dy + waist,
          center.dx - r, center.dy)
      ..quadraticBezierTo(center.dx - waist, center.dy - waist,
          center.dx, center.dy - r)
      ..close();
    canvas.drawPath(starPath, Paint()..color = star);
  }

  Path _rotatedRing(
      Offset center, double width, double height, double radians) {
    final Path ring = Path()
      ..addOval(Rect.fromCenter(center: center, width: width, height: height));
    final Matrix4 matrix = Matrix4.identity()
      ..translate(center.dx, center.dy)
      ..rotateZ(radians)
      ..translate(-center.dx, -center.dy);
    return ring.transform(matrix.storage);
  }

  @override
  bool shouldRepaint(_BrandMarkPainter oldDelegate) =>
      oldDelegate.star != star ||
      oldDelegate.teal != teal ||
      oldDelegate.amber != amber;
}

/// 圆角方形徽标底座：把 [BrandMark] 放进半透明玻璃里，用作标题栏图标。
class BrandBadge extends StatelessWidget {
  const BrandBadge({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Colors.white.withOpacity(0.28),
            Colors.white.withOpacity(0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: Colors.white.withOpacity(0.35)),
      ),
      padding: EdgeInsets.all(size * 0.16),
      child: BrandMark(size: size * 0.68),
    );
  }
}
