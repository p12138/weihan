import 'package:flutter/material.dart';

import 'conversation_page.dart';

void main() => runApp(const BaseApp());

/// 应用外壳。保留 BaseApp 名称，便于既有测试与文档引用。
class BaseApp extends StatelessWidget {
  const BaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '维汉互译',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: ConversationPage(),
    );
  }
}
