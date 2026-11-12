import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/update_dialog.dart';
import 'package:uyghur_interpreter/update_installer.dart';
import 'package:uyghur_interpreter/update_manifest.dart';
import 'package:uyghur_interpreter/update_service.dart';
import 'package:uyghur_interpreter/update_store.dart';

class _FakeGateway implements UpdateGateway {
  _FakeGateway({this.bytes = const <int>[]});

  String body = '';
  List<int> bytes;

  @override
  Future<String> getText(Uri uri) async => body;

  @override
  Future<void> downloadTo(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    target.writeAsBytesSync(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}

class _FakeInstaller implements UpdateInstaller {
  File? installed;
  String? opened;

  @override
  Future<bool> installApk(File apk) async {
    installed = apk;
    return true;
  }

  @override
  Future<bool> openUrl(String url) async {
    opened = url;
    return true;
  }
}

void main() {
  late _FakeGateway gateway;
  late _FakeInstaller installer;
  late Directory tmp;

  const List<int> payload = <int>[7, 8, 9];
  final String digest = sha256.convert(payload).toString();

  final UpdateManifest manifest = UpdateManifest(
    platform: 'android',
    version: '0.5.0',
    build: 1,
    notes: '修复翻译等待',
    file: 'app.apk',
    size: payload.length,
    sha256: digest,
    requiresResign: false,
  );

  setUp(() {
    gateway = _FakeGateway(bytes: payload);
    installer = _FakeInstaller();
    tmp = Directory.systemTemp.createTempSync('weihan_dialog_test_');
    UpdateStore.writeBaseUrl('https://a.example.com/weihan');
  });

  tearDown(() {
    UpdateStore.writeBaseUrl('');
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  UpdateService serviceFor(String platform, {String current = '0.4.6+1'}) {
    return UpdateService(
      gateway: gateway,
      installer: installer,
      currentVersion: current,
      platform: platform,
      downloadDir: tmp,
    );
  }

  /// 不用 pumpAndSettle：检查阶段有无限旋转的进度圈，settle 会一直等；
  /// 而下载涉及真实文件 IO，必须借 runAsync 让它跑完。
  Future<void> pumpDialog(
    WidgetTester tester, {
    required UpdateService service,
    UpdateManifest? withManifest,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateDialog(service: service, manifest: withManifest),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
  }

  testWidgets('显示最新版本、体积与更新说明', (WidgetTester tester) async {
    await pumpDialog(
      tester,
      service: serviceFor('android'),
      withManifest: manifest,
    );

    expect(find.textContaining('0.5.0'), findsOneWidget);
    expect(find.text('修复翻译等待'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget);
  });

  testWidgets('Android 下载完成后交给系统安装器', (WidgetTester tester) async {
    await pumpDialog(
      tester,
      service: serviceFor('android'),
      withManifest: manifest,
    );

    await tester.tap(find.text('下载并安装'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    await tester.pump();

    expect(installer.installed, isNotNull);
    expect(installer.installed!.readAsBytesSync(), payload);
    expect(find.textContaining('已交给系统安装器'), findsOneWidget);
  });

  testWidgets('iOS 改成打开下载页并说明要重签', (WidgetTester tester) async {
    await pumpDialog(
      tester,
      service: serviceFor('ios'),
      withManifest: manifest,
    );

    expect(find.textContaining('重签'), findsWidgets);
    await tester.tap(find.text('打开下载页'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    await tester.pump();

    expect(installer.opened, 'https://a.example.com/weihan/app.apk');
    expect(find.textContaining('已打开下载页'), findsOneWidget);
  });

  testWidgets('没有新版时明确说已是最新', (WidgetTester tester) async {
    gateway.body = '''
{
  "schema": 1,
  "platform": "android",
  "version": "0.4.6",
  "build": 1,
  "notes": "",
  "file": "app.apk",
  "size": 3,
  "sha256": "$digest",
  "requiresResign": false
}
''';
    await pumpDialog(tester, service: serviceFor('android'));

    expect(
      find.byKey(const ValueKey<String>('update-up-to-date')),
      findsOneWidget,
    );
  });
}
