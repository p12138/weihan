import 'dart:async';

import 'package:flutter/material.dart';

import 'conversation_page.dart';
import 'device_audio.dart';
import 'palette_controller.dart';
import 'splash_page.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 读上次选的主题；读不到就用默认的艾德莱斯配色。
  PaletteController.instance.load();
  runApp(BaseApp(
    showSplash: true,
    // 启动页读完再弹麦克风授权框：系统弹窗不会盖住要看的品牌文字。
    // 权限依然是「提前问」，只是提前到用户准备开始说话之前，不是按住那一刻。
    onSplashFinished: () => unawaited(primeMicrophonePermission()),
  ));
}

/// 应用外壳。保留 BaseApp 名称，便于既有测试与文档引用。
class BaseApp extends StatelessWidget {
  const BaseApp({
    super.key,
    this.showSplash = false,
    this.splashHold = kSplashHold,
    this.onSplashFinished,
  });

  /// 只有真正的 main() 会打开。widget 测试 pump `const BaseApp()` 时直接进
  /// 对话页：既不必等两秒多，也不会让「融合」「标语」在首屏命中两份。
  final bool showSplash;

  /// 启动页停留时长，抽成参数方便测试里缩短。
  final Duration splashHold;

  final VoidCallback? onSplashFinished;

  @override
  Widget build(BuildContext context) {
    // 主题一变就整棵树重建：色板是全局静态读的，不重建就看不到新颜色。
    return AnimatedBuilder(
      animation: PaletteController.instance,
      builder: (BuildContext context, Widget? child) {
        return MaterialApp(
          title: '融合',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          // 这个工具只用浅色：面对面沟通多在明亮环境，深色版本只会多一套要维护的配色。
          darkTheme: AppTheme.light(),
          themeMode: ThemeMode.light,
          builder: (BuildContext context, Widget? inner) {
            // 系统字号放大到 1.3 倍以上时气泡与输入区会挤成一团，这里做温和收口。
            return MediaQuery.withClampedTextScaling(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.3,
              child: inner ?? const SizedBox.shrink(),
            );
          },
          home: showSplash
              ? SplashGate(
                  hold: splashHold,
                  onFinished: onSplashFinished,
                  child: ConversationPage(),
                )
              : ConversationPage(),
        );
      },
    );
  }
}
