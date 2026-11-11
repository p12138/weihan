import 'dart:async';

import 'package:flutter/material.dart';

import 'conversation_page.dart';
import 'device_audio.dart';
import 'palette_controller.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 读上次选的主题；读不到就用默认的艾德莱斯配色。
  PaletteController.instance.load();
  runApp(const BaseApp());
  // 首帧之后再弹麦克风授权框：既不盖在原生启动页上，也不会在用户
  // 第一次按住说话时弹出来把那次录音抢废。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(primeMicrophonePermission());
  });
}

/// 应用外壳。保留 BaseApp 名称，便于既有测试与文档引用。
class BaseApp extends StatelessWidget {
  const BaseApp({super.key});

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
          home: ConversationPage(),
        );
      },
    );
  }
}
