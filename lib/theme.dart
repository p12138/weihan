import 'package:flutter/material.dart';

/// 一套完整配色。
///
/// 所有字段都是 const，切主题只是换一个实例，不会重建任何组件树。
/// 「主色」永远是中文侧的颜色，「强调色」永远是维文侧的颜色 —— 这样换主题时
/// 界面里「哪种语言配哪个颜色」的关系不会乱，只是配色换了皮。
@immutable
class BrandPalette {
  const BrandPalette({
    required this.id,
    required this.name,
    required this.note,
    required this.primary,
    required this.primaryLight,
    required this.primaryDeep,
    required this.primarySoft,
    required this.accent,
    required this.accentSoft,
    required this.accentInk,
    required this.coral,
    required this.canvas,
    required this.ink,
    required this.inkMuted,
    required this.line,
  });

  /// 持久化用的稳定标识，改名不影响已保存的选择。
  final String id;

  /// 设置页里显示的名字。
  final String name;

  /// 一句话说明这套配色的来源，方便自己记住为什么选它。
  final String note;

  /// 主色：中文侧、主按钮、标题栏。
  final Color primary;

  /// 主色浅阶：渐变上沿（依然要够深，白字才看得清）。
  final Color primaryLight;

  /// 主色深阶：渐变下沿、深色文字。
  final Color primaryDeep;

  /// 主色浅底：选中态、浅底提示条。
  final Color primarySoft;

  /// 强调色：维文侧、次要操作。
  final Color accent;

  /// 强调色浅底：标签、提示卡。
  final Color accentSoft;

  /// 强调色上的文字色（浅底深字）。
  final Color accentInk;

  /// 警示色：录音中、错误。
  final Color coral;

  /// 页面底色。
  final Color canvas;

  /// 正文墨色。
  final Color ink;

  /// 次要文字。
  final Color inkMuted;

  /// 描边。
  final Color line;

  /// 顶栏 / 自己的气泡用同一条渐变，保证同一套视觉语言。
  LinearGradient get gradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[primaryLight, primaryDeep],
      );

  /// 语言 → 颜色。中文侧主色，维文侧强调色。
  Color colorOf(bool uyghur) => uyghur ? accent : primary;

  /// 该语言对应的浅底色。
  Color softOf(bool uyghur) => uyghur ? accentSoft : primarySoft;

  /// 该语言的渐变：中文走主色梯度，维文走强调色梯度。
  /// 强调色的深端用 [accentInk]，它本来就是为「压住白字」挑的深色。
  LinearGradient gradientOf(bool uyghur) => uyghur
      ? LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[accent, accentInk],
        )
      : gradient;

  /// 设置页主题选择器上的两个色点。
  List<Color> get swatch => <Color>[primary, accent];

  /// 艾德莱斯绸：松石绿 + 沙金。默认主题，取自维吾尔族传统织物。
  static const BrandPalette adeles = BrandPalette(
    id: 'adeles',
    name: '艾德莱斯',
    note: '松石绿 · 沙金',
    primary: Color(0xFF17635C),
    primaryLight: Color(0xFF1B7168),
    primaryDeep: Color(0xFF0B3A36),
    primarySoft: Color(0xFFDCEBE7),
    accent: Color(0xFFC89544),
    accentSoft: Color(0xFFF6E9D2),
    accentInk: Color(0xFF7A5A22),
    coral: Color(0xFFC1543F),
    canvas: Color(0xFFFBF8F3),
    ink: Color(0xFF16302C),
    inkMuted: Color(0xFF6B7F7A),
    line: Color(0xFFE2E8E4),
  );

  /// 哔哩哔哩：官方粉 #FB7299 + 官方蓝 #00A1D6。
  static const BrandPalette bilibili = BrandPalette(
    id: 'bilibili',
    name: 'B 站',
    note: '哔哩哔哩粉 · 天依蓝',
    primary: Color(0xFFFB7299),
    primaryLight: Color(0xFFF0618C),
    primaryDeep: Color(0xFF8A2547),
    primarySoft: Color(0xFFFDE3EC),
    accent: Color(0xFF00A1D6),
    accentSoft: Color(0xFFDDF2FB),
    accentInk: Color(0xFF08536D),
    coral: Color(0xFFE5383B),
    canvas: Color(0xFFFFF9FB),
    ink: Color(0xFF2A2A35),
    inkMuted: Color(0xFF71717E),
    line: Color(0xFFF2E3E9),
  );

  /// 石榴：南疆石榴汁的红，配麦色金。
  static const BrandPalette pomegranate = BrandPalette(
    id: 'pomegranate',
    name: '石榴',
    note: '石榴红 · 麦金',
    primary: Color(0xFFA62B3C),
    primaryLight: Color(0xFFB93B4C),
    primaryDeep: Color(0xFF63141F),
    primarySoft: Color(0xFFF7E1E5),
    accent: Color(0xFFD9A441),
    accentSoft: Color(0xFFFBEFD8),
    accentInk: Color(0xFF7A5426),
    coral: Color(0xFFE4572E),
    canvas: Color(0xFFFDF7F4),
    ink: Color(0xFF331E1C),
    inkMuted: Color(0xFF7A6460),
    line: Color(0xFFEEDFD9),
  );

  /// 靛蓝：夜里的喀什蓝砖，配警示黄。
  static const BrandPalette indigo = BrandPalette(
    id: 'indigo',
    name: '靛蓝',
    note: '湖蓝 · 琥珀',
    primary: Color(0xFF3D5AFE),
    primaryLight: Color(0xFF4462D8),
    primaryDeep: Color(0xFF1A237E),
    primarySoft: Color(0xFFE3E8FF),
    accent: Color(0xFFE8A33D),
    accentSoft: Color(0xFFFDF0DA),
    accentInk: Color(0xFF7A5800),
    coral: Color(0xFFFF5252),
    canvas: Color(0xFFF7F8FE),
    ink: Color(0xFF1B2033),
    inkMuted: Color(0xFF6B7285),
    line: Color(0xFFE2E6F5),
  );

  /// 可选主题，顺序即设置页里的展示顺序。
  static const List<BrandPalette> all = <BrandPalette>[
    adeles,
    bilibili,
    pomegranate,
    indigo,
  ];

  /// 按 id 找主题；找不到（旧版本存的值、文件被改坏）一律回默认。
  static BrandPalette byId(String? id) => all.firstWhere(
        (BrandPalette palette) => palette.id == id,
        orElse: () => adeles,
      );
}

/// 全局色板入口。
///
/// 这里刻意用「全局可变 + 静态 getter」而不是 InheritedWidget：
/// 全工程有 80 多处取色，逐个传 context 只会让组件签名变脏。
/// 一次只显示一套配色，切主题时先赋值再 notifyListeners，重建时读到的就是新值。
///
/// 代价：这些颜色不再是编译期常量，任何 `const Widget(... color: AppColors.x)`
/// 都必须去掉 const。新增取色点时注意这一点。
class AppColors {
  AppColors._();

  /// 当前配色。切主题时先改这个字段，再 notifyListeners 让界面重建。
  static BrandPalette palette = BrandPalette.adeles;

  static Color get primary => palette.primary;

  static Color get primaryLight => palette.primaryLight;

  static Color get primaryDeep => palette.primaryDeep;

  static Color get primarySoft => palette.primarySoft;

  static Color get accent => palette.accent;

  /// 强调色的旧名字，历史代码里写作 sand（沙金）。
  static Color get sand => palette.accent;

  static Color get accentSoft => palette.accentSoft;

  static Color get sandSoft => palette.accentSoft;

  static Color get accentInk => palette.accentInk;

  static Color get coral => palette.coral;

  static Color get canvas => palette.canvas;

  static Color get card => Colors.white;

  static Color get ink => palette.ink;

  static Color get inkMuted => palette.inkMuted;

  static Color get line => palette.line;

  /// 主渐变：主色浅阶 → 主色深阶。顶栏、自己的气泡、主按钮、语音条共用。
  static LinearGradient get gradient => palette.gradient;

  /// 顶栏渐变。
  static LinearGradient get headerGradient => palette.gradient;

  /// 自己的气泡 / 主按钮渐变。
  static LinearGradient get bubbleGradient => palette.gradient;

  /// 语言色：中文侧主色、维文侧强调色。
  static Color language(bool uyghur) => palette.colorOf(uyghur);

  /// 语言浅底。
  static Color languageSoft(bool uyghur) => palette.softOf(uyghur);

  /// 语言渐变。
  static LinearGradient gradientOf(bool uyghur) => palette.gradientOf(uyghur);
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

  /// 按 [AppColors.palette] 建主题。切主题时必须先改色板再调用本方法。
  static ThemeData light() {
    final BrandPalette palette = AppColors.palette;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: palette.primary,
      primary: palette.primary,
      onPrimary: Colors.white,
      primaryContainer: palette.primarySoft,
      onPrimaryContainer: palette.primaryDeep,
      secondary: palette.accent,
      onSecondary: Colors.white,
      secondaryContainer: palette.accentSoft,
      onSecondaryContainer: palette.accentInk,
      surface: palette.canvas,
      onSurface: palette.ink,
      error: palette.coral,
      outlineVariant: palette.line,
    );

    final TextTheme base = Typography.material2021().black.apply(
          bodyColor: palette.ink,
          displayColor: palette.ink,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.canvas,
      fontFamilyFallback: _fallback,
      textTheme: base.copyWith(
        // 标题：略收紧字距，中文小标题更整齐
        titleLarge: base.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: palette.ink,
        ),
        titleMedium: base.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: palette.ink,
        ),
        bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: 14.5, height: 1.5),
        bodySmall: base.bodySmall?.copyWith(
          fontSize: 12.5,
          height: 1.45,
          color: palette.inkMuted,
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
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: TextStyle(color: palette.inkMuted, fontSize: 14.5),
        labelStyle: TextStyle(color: palette.inkMuted, fontSize: 14.5),
        border: _inputBorder(palette.line, 1),
        enabledBorder: _inputBorder(palette.line, 1),
        focusedBorder: _inputBorder(palette.primary, 1.6),
        errorBorder: _inputBorder(palette.coral, 1.2),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.primary,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: palette.primary,
          elevation: 0,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: palette.primary),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: base.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: palette.ink,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: palette.line,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: palette.primaryDeep,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.primaryDeep.withOpacity(0.94),
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
  static TextStyle get uyghurBody => TextStyle(
        fontSize: 19,
        height: 1.95,
        fontWeight: FontWeight.w500,
        color: AppColors.ink,
      );
}
