import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// 玻璃层级：同一套 UI，在不同系统上"厚薄"不同。
///
/// * [solid]  —— 不做模糊，纯半透明实色。老系统上更稳，不会出现大面积重绘。
/// * [frosted]—— 经典磨砂：背景模糊 + 半透明白。
/// * [liquid] —— iOS 26 起的液态玻璃观感：更厚的模糊、更大圆角、顶部高光与亮边。
enum GlassKind { solid, frosted, liquid }

/// 一次解析好的玻璃参数，全局复用，避免每帧重新判断系统版本。
@immutable
class GlassSpec {
  const GlassSpec({
    required this.kind,
    required this.blur,
    required this.fillOpacity,
    required this.corner,
    required this.borderOpacity,
    required this.specular,
    required this.label,
  });

  final GlassKind kind;

  /// 背景模糊半径（sigma）。0 表示不模糊。
  final double blur;

  /// 填充白色的不透明度，越低越"透"。
  final double fillOpacity;

  /// 圆角半径。
  final double corner;

  /// 边缘亮线的不透明度。
  final double borderOpacity;

  /// 是否叠一层顶部高光（液态玻璃才有）。
  final bool specular;

  /// 诊断用：当前命中的是哪一条规则，设置页可以显示。
  final String label;

  static const GlassSpec solidSystem = GlassSpec(
    kind: GlassKind.solid,
    blur: 0,
    fillOpacity: 0.94,
    corner: 18,
    borderOpacity: 0.06,
    specular: false,
    label: '实色（旧系统）',
  );

  static const GlassSpec frostedIOS = GlassSpec(
    kind: GlassKind.frosted,
    blur: 22,
    fillOpacity: 0.72,
    corner: 20,
    borderOpacity: 0.28,
    specular: false,
    label: '磨砂玻璃（iOS 17 / 18）',
  );

  static const GlassSpec liquidIOS = GlassSpec(
    kind: GlassKind.liquid,
    blur: 30,
    fillOpacity: 0.56,
    corner: 26,
    borderOpacity: 0.46,
    specular: true,
    label: '液态玻璃（iOS 26+）',
  );

  static const GlassSpec frostedAndroid = GlassSpec(
    kind: GlassKind.frosted,
    blur: 16,
    fillOpacity: 0.80,
    corner: 20,
    borderOpacity: 0.20,
    specular: false,
    label: '磨砂玻璃（Android）',
  );
}

/// 玻璃风格解析器：按平台与系统大版本选参数。
///
/// iOS 17 / 18 用磨砂，iOS 26 及以后（含 27）用液态玻璃，
/// 更老的 iOS 与任何解析不出来的情况退回实色 —— 宁可少特效，也不要糊成一片。
class Glass {
  const Glass._();

  static GlassSpec? _override;
  static GlassSpec? _cached;

  /// 测试或截图对比时强制指定，传 null 恢复正常解析。
  @visibleForTesting
  static set override(GlassSpec? spec) {
    _override = spec;
    _cached = spec;
  }

  static GlassSpec get spec => _cached ??= _resolve();

  /// 当前 iOS 主版本号；非 iOS 或解析失败返回 null。
  static int? get iOsMajorVersion {
    if (kIsWeb || !Platform.isIOS) {
      return null;
    }
    // 形如 "Version 18.2 (Build 22C152)" 或 "17.4 (21E219)"
    final RegExpMatch? match =
        RegExp(r'(\d+)\.(\d+)').firstMatch(Platform.operatingSystemVersion);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1) ?? '');
  }

  static GlassSpec _resolve() {
    final GlassSpec? forced = _override;
    if (forced != null) {
      return forced;
    }
    final int? ios = iOsMajorVersion;
    if (ios != null) {
      if (ios >= 26) {
        return GlassSpec.liquidIOS;
      }
      if (ios >= 17) {
        return GlassSpec.frostedIOS;
      }
      return GlassSpec.solidSystem;
    }
    if (kIsWeb) {
      return GlassSpec.solidSystem;
    }
    return GlassSpec.frostedAndroid;
  }
}

/// 玻璃容器：圆角裁剪 + 背景模糊 + 半透明填充 + 亮边。
///
/// 只模糊「自己身后」的内容（BackdropFilter 限定在 ClipRRect 内），
/// 所以页面上要有一层彩色底（[AuroraBackground]）才好看，否则等于给纯白糊了一层。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.corner,
    this.blur,
    this.fillOpacity,
    this.tint,
    this.showBorder = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// 覆盖默认圆角；不传用 [Glass.spec] 的值。
  final double? corner;

  /// 覆盖默认模糊半径；传 0 表示这块不模糊（例如对话框滚动区）。
  final double? blur;

  final double? fillOpacity;

  /// 填充底色，默认近白。
  final Color? tint;

  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final GlassSpec spec = Glass.spec;
    final double radius = corner ?? spec.corner;
    final double sigma = blur ?? spec.blur;
    final double opacity = fillOpacity ?? spec.fillOpacity;
    final Color base = (tint ?? Colors.white).withOpacity(opacity);
    final BorderRadius shape = BorderRadius.circular(radius);

    Widget surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: base,
        borderRadius: shape,
        border: showBorder
            ? Border.all(
                color: Colors.white.withOpacity(spec.borderOpacity),
                width: 1,
              )
            : null,
      ),
      child: child,
    );

    if (spec.specular) {
      // 液态玻璃：顶部一道斜向高光，模拟玻璃边缘折射
      surface = Stack(
        children: <Widget>[
          surface,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: shape,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    stops: const <double>[0.0, 0.35, 0.36, 1.0],
                    colors: <Color>[
                      Colors.white.withOpacity(0.30),
                      Colors.white.withOpacity(0.06),
                      Colors.white.withOpacity(0.0),
                      Colors.white.withOpacity(0.04),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget inner = surface;
    if (sigma > 0) {
      inner = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: surface,
      );
    }
    final Widget clipped = ClipRRect(borderRadius: shape, child: inner);

    // 外投影只在有模糊时加，实色面板加阴影会显得很脏
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: sigma > 0
            ? <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFF0B3A36).withOpacity(0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: clipped,
    );
  }
}

/// 页面底纹：松石绿与沙金的柔光斑，给玻璃层提供可折射的内容。
/// 三团径向渐变，静态绘制，不做动画（E2E 依赖 pumpAndSettle 能收敛）。
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: AppColors.canvas),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: -120,
            left: -80,
            child: _Blob(
              size: 320,
              color: AppColors.primary.withOpacity(0.20),
            ),
          ),
          Positioned(
            top: 140,
            right: -110,
            child: _Blob(
              size: 300,
              color: AppColors.sand.withOpacity(0.18),
            ),
          ),
          Positioned(
            bottom: -140,
            left: 40,
            child: _Blob(
              size: 340,
              color: AppColors.primary.withOpacity(0.10),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withOpacity(0.0)],
          ),
        ),
      ),
    );
  }
}
