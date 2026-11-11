import 'package:flutter/material.dart';

/// 品牌色板：取色自艾德莱斯绸的松石绿与沙金，配暖白纸感底色。
///
/// 为什么不直接用 `ColorScheme.fromSeed` 自动配色：自动方案会把
/// 主色、容器色、强调色都洗成同一支灰调，界面看着"能用但没记住点"。
/// 这里手动定几个关键色，只让 fromSeed 负责它擅长的部分（反色、错误色等）。
class AppColors {
  const AppColors._();

  /// 主色：松石绿。标题栏、自己的气泡、主按钮。
  static const Color primary = Color(0xFF17635C);

  /// 主色深阶：渐变下沿、深色文字。
  static const Color primaryDeep = Color(0xFF0B3A36);

  /// 主色浅阶：选中态、浅底提示条。
  static const Color primarySoft = Color(0xFFDCEBE7);

  /// 强调色：沙金。维文侧气泡、强调标记。
  static const Color sand = Color(0xFFC89544);

  /// 沙金浅阶：标签底色。
  static const Color sandSoft = Color(0xFFF6E9D2);

  /// 石榴红：录音中、错误提示。
  static const Color coral = Color(0xFFC1543F);

  /// 页面底色：暖白，不刺眼。
  static const Color canvas = Color(0xFFFBF8F3);

  /// 卡片 / 气泡底色。
  static const Color card = Color(0xFFFFFFFF);

  /// 正文墨色。
  static const Color ink = Color(0xFF16302C);

  /// 次要文字。
  static const Color inkMuted = Color(0xFF6B7F7A);

  /// 描边。
  static const Color line = Color(0xFFE2E8E4);

  /// 标题栏渐变。
  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF1B7168), primaryDeep],
  );
}

/// 全局主题。只做浅色主题：这是一个自用工具，深色模式只会增加
/// 两套配色都要维护的成本，而实际使用场景（户外、面对面沟通）以亮色为主。
class AppTheme {
  const AppTheme._();

  /// 中维混排的字体回退链。维吾尔文用阿拉伯字母，Android 上若正文字体
  /// 不含该字形，会退化到豆腐块；显式列出常见阿拉伯字体做兜底。
  static const List<String> _fallback = <String>[
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'PingFang SC',
    'Microsoft YaHei',
    'Noto Naskh Arabic',
    'Noto Sans Arabic',
    'Geeza Pro',
  ];

  static ThemeData light() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: AppColors.primarySoft,
      onPrimaryContainer: AppColors.primaryDeep,
      secondary: AppColors.sand,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.sandSoft,
      onSecondaryContainer: const Color(0xFF5E4013),
      surface: AppColors.canvas,
      onSurface: AppColors.ink,
      error: AppColors.coral,
      outlineVariant: AppColors.line,
    );

    final TextTheme base = Typography.material2021().black.apply(
          bodyColor: AppColors.ink,
          displayColor: AppColors.ink,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      fontFamilyFallback: _fallback,
      textTheme: base.copyWith(
        // 标题：略收紧字距，中文小标题更整齐
        titleLarge: base.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: AppColors.ink,
        ),
        titleMedium: base.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
        bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: 14.5, height: 1.5),
        bodySmall: base.bodySmall?.copyWith(
          fontSize: 12.5,
          height: 1.45,
          color: AppColors.inkMuted,
        ),
        labelLarge: base.labelLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: AppColors.inkMuted, fontSize: 14.5),
        labelStyle: const TextStyle(color: AppColors.inkMuted, fontSize: 14.5),
        border: _inputBorder(AppColors.line, 1),
        enabledBorder: _inputBorder(AppColors.line, 1),
        focusedBorder: _inputBorder(AppColors.primary, 1.6),
        errorBorder: _inputBorder(AppColors.coral, 1.2),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.card,
          foregroundColor: AppColors.primary,
          elevation: 0,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: AppColors.primary),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: base.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.primaryDeep,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.primaryDeep.withOpacity(0.94),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12.5),
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }

  static OutlineInputBorder _inputBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );

  /// 维吾尔文等比正文需要更松的行距，阿拉伯字母连写才不挤。
  static const TextStyle uyghurBody = TextStyle(
    fontSize: 19,
    height: 1.95,
    fontWeight: FontWeight.w500,
    color: AppColors.ink,
  );
}
