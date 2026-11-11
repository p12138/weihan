import 'package:flutter/material.dart';

import 'theme.dart';

/// 应用标识：与安装图标同源的「两枚对话气泡」。
///
/// 和 `scripts/make_icons.py` 里的几何保持同一套比例（气泡位置、字条长度、
/// 尾巴角度都对齐），这样启动图、桌面图标、应用内标识看起来是同一个东西。
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 36,
    this.bubble = Colors.white,
    this.accent = AppColors.sand,
    this.ink = AppColors.primaryDeep,
  });

  /// 标识整体边长（正方形）。
  final double size;

  /// 上方气泡（中文侧）颜色。
  final Color bubble;

  /// 下方气泡（维文侧）颜色。
  final Color accent;

  /// 气泡内文字条颜色。
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BrandMarkPainter(
          bubble: bubble,
          accent: accent,
          ink: ink,
        ),
      ),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter({
    required this.bubble,
    required this.accent,
    required this.ink,
  });

  final Color bubble;
  final Color accent;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final double cx = size.width / 2;
    final double cy = size.height / 2;

    double px(double v) => cx + v * s;
    double py(double v) => cy + v * s;

    // 白色气泡 + 左下小尾巴
    final Path white = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(px(-0.16), py(-0.14)),
            width: 0.56 * s,
            height: 0.37 * s,
          ),
          Radius.circular(0.085 * s),
        ),
      )
      ..addPath(
        Path()
          ..moveTo(px(-0.38), py(0.015))
          ..lineTo(px(-0.19), py(0.015))
          ..lineTo(px(-0.365), py(0.185))
          ..close(),
        Offset.zero,
      );
    canvas.drawPath(white, Paint()..color = bubble);

    // 中文侧两行字
    _bar(canvas, px(-0.245), py(-0.195), 0.30 * s, 0.052 * s);
    _bar(canvas, px(-0.245), py(-0.075), 0.21 * s, 0.052 * s);

    // 沙金气泡（压在白色气泡右下角之上）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(px(0.17), py(0.17)),
          width: 0.54 * s,
          height: 0.36 * s,
        ),
        Radius.circular(0.085 * s),
      ),
      Paint()..color = accent,
    );
    // 维文侧一行连写
    _bar(canvas, px(0.19), py(0.165), 0.30 * s, 0.052 * s, color: ink);
  }

  void _bar(
    Canvas canvas,
    double cx,
    double cy,
    double width,
    double height, {
    Color? color,
  }) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: width, height: height),
        Radius.circular(height / 2),
      ),
      Paint()..color = color ?? ink,
    );
  }

  @override
  bool shouldRepaint(_BrandMarkPainter oldDelegate) =>
      oldDelegate.bubble != bubble ||
      oldDelegate.accent != accent ||
      oldDelegate.ink != ink;
}

/// 圆形 / 圆角方形徽标底座：把 [BrandMark] 放进渐变底里，用作标题栏图标。
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
