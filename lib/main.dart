import 'package:flutter/material.dart';

import 'conversation_page.dart';
import 'theme.dart';

void main() => runApp(const BaseApp());

/// 应用外壳。保留 BaseApp 名称，便于既有测试与文档引用。
class BaseApp extends StatelessWidget {
  const BaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '融合',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      // 这个工具只用浅色：面对面沟通多在明亮环境，深色版本只会多一套要维护的配色。
      darkTheme: AppTheme.light(),
      themeMode: ThemeMode.light,
      builder: (BuildContext context, Widget? child) {
        // 系统字号放大到 1.3 倍以上时气泡与输入区会挤成一团，这里做温和收口。
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.3,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: ConversationPage(),
    );
  }
}
