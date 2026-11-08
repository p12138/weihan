import 'package:flutter/material.dart';

void main() => runApp(const BaseApp());

/// 工具链验证地基页，不是业务界面。
///
/// 拿到《维汉互译 App》原源码后，用原工程的 lib/ 覆盖本目录即可；
/// android/、ios/、.github/workflows/ 与 scripts/ 可以直接沿用。
class BaseApp extends StatelessWidget {
  const BaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '维汉互译 · 地基',
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '工具链地基 · 这一步只验证 Flutter 3.24.0 / Java 17 / Gradle 能产出 debug APK',
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                Text('拿到原工程源码后，请用其 lib/ 覆盖本目录。'),
                SizedBox(height: 24),
                Directionality(
                  textDirection: TextDirection.rtl,
                  child: Text(
                    'ئۇيغۇرچە خەت سىنىقى',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
