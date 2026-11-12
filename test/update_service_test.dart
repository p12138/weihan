import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/update_installer.dart';
import 'package:uyghur_interpreter/update_manifest.dart';
import 'package:uyghur_interpreter/update_service.dart';

class _FakeGateway implements UpdateGateway {
  String body = '';
  List<int> bytes = const <int>[];
  Object? error;
  int downloads = 0;
  Uri? lastDownloadUri;

  @override
  Future<String> getText(Uri uri) async {
    if (error != null) {
      throw error!;
    }
    return body;
  }

  @override
  Future<void> downloadTo(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    downloads += 1;
    lastDownloadUri = uri;
    if (error != null) {
      throw error!;
    }
    target.writeAsBytesSync(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}

class _FakeInstaller implements UpdateInstaller {
  File? installed;
  String? opened;
  bool installResult = true;
  bool openResult = true;

  @override
  Future<bool> installApk(File apk) async {
    installed = apk;
    return installResult;
  }

  @override
  Future<bool> openUrl(String url) async {
    opened = url;
    return openResult;
  }
}

String _manifestJson({
  String version = '0.5.0',
  String platform = 'android',
  String sha256 =
      '2ff5eed3a728924725462592a9e052c5df44968f0d96c888079b26e7831eee45',
}) {
  return '''
{
  "schema": 1,
  "platform": "$platform",
  "version": "$version",
  "build": 1,
  "notes": "测试",
  "file": "app.apk",
  "size": 3,
  "sha256": "$sha256",
  "requiresResign": false
}
''';
}

UpdateManifest _manifest({required String sha256, String version = '0.5.0'}) {
  return UpdateManifest(
    platform: 'android',
    version: version,
    build: 1,
    notes: '测试',
    file: 'app.apk',
    size: 3,
    sha256: sha256,
    requiresResign: false,
  );
}

void main() {
  late _FakeGateway gateway;
  late _FakeInstaller installer;
  late Directory tmp;

  setUp(() {
    gateway = _FakeGateway();
    installer = _FakeInstaller();
    tmp = Directory.systemTemp.createTempSync('weihan_update_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  UpdateService buildService({String currentVersion = '0.4.6+1'}) {
    return UpdateService(
      gateway: gateway,
      installer: installer,
      currentVersion: currentVersion,
      platform: 'android',
      downloadDir: tmp,
    );
  }

  group('manifestUri', () {
    test('目录补平台清单名', () {
      final UpdateService service = buildService();
      expect(
        service.manifestUri('https://a.example.com/weihan').toString(),
        'https://a.example.com/weihan/latest-android.json',
      );
      expect(
        service.manifestUri('https://a.example.com/weihan/').toString(),
        'https://a.example.com/weihan/latest-android.json',
      );
    });

    test('完整 json 地址原样使用', () {
      final UpdateService service = buildService();
      expect(
        service
            .manifestUri('https://a.example.com/x/latest-android.json')
            .toString(),
        'https://a.example.com/x/latest-android.json',
      );
    });

    test('空地址与缺协议都给出可读错误', () {
      final UpdateService service = buildService();
      expect(
        () => service.manifestUri(''),
        throwsA(
          isA<UpdateException>().having(
            (UpdateException e) => e.message,
            'message',
            contains('还没有配置'),
          ),
        ),
      );
      expect(
        () => service.manifestUri('a.example.com/weihan'),
        throwsA(
          isA<UpdateException>().having(
            (UpdateException e) => e.message,
            'message',
            contains('不完整'),
          ),
        ),
      );
    });
  });

  group('check', () {
    test('发现新版本', () async {
      gateway.body = _manifestJson();
      final UpdateCheck result =
          await buildService().check('https://a.example.com/weihan');
      expect(result.status, UpdateCheckStatus.available);
      expect(result.manifest?.version, '0.5.0');
    });

    test('同版本不算更新', () async {
      gateway.body = _manifestJson();
      final UpdateCheck result =
          await buildService(currentVersion: '0.5.0+1')
              .check('https://a.example.com/weihan');
      expect(result.status, UpdateCheckStatus.upToDate);
    });

    test('清单坏了要保留原因', () async {
      gateway.body = 'not-json';
      final UpdateCheck result =
          await buildService().check('https://a.example.com/weihan');
      expect(result.status, UpdateCheckStatus.failed);
      expect(result.error, contains('格式'));
    });

    test('平台不匹配时拒绝，避免安卓装到 iOS 包', () async {
      gateway.body = _manifestJson(platform: 'ios');
      final UpdateCheck result =
          await buildService().check('https://a.example.com/weihan');
      expect(result.status, UpdateCheckStatus.failed);
      expect(result.error, contains('ios'));
      expect(result.error, contains('android'));
    });

    test('网络异常不抛出，转成 failed', () async {
      gateway.error = const SocketException('Connection refused');
      final UpdateCheck result =
          await buildService().check('https://a.example.com/weihan');
      expect(result.status, UpdateCheckStatus.failed);
      expect(result.error, contains('连不上更新服务器'));
    });
  });

  group('download', () {
    test('校验通过后返回文件', () async {
      final List<int> bytes = <int>[1, 2, 3];
      gateway.bytes = bytes;
      final String digest = sha256.convert(bytes).toString();
      final UpdateManifest manifest = _manifest(sha256: digest);
      final Uri uri = Uri.parse('https://a.example.com/weihan/latest-android.json');

      final File file = await buildService().download(manifest, uri);
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), bytes);
      expect(
        gateway.lastDownloadUri.toString(),
        'https://a.example.com/weihan/app.apk',
      );
    });

    test('校验失败时删掉文件并说明原因', () async {
      gateway.bytes = <int>[9, 9, 9];
      final UpdateManifest manifest = _manifest(
        sha256: '0'.padRight(64, '0'),
      );
      final Uri uri = Uri.parse('https://a.example.com/weihan/latest-android.json');

      await expectLater(
        buildService().download(manifest, uri),
        throwsA(
          isA<UpdateException>().having(
            (UpdateException e) => e.message,
            'message',
            contains('校验失败'),
          ),
        ),
      );
      expect(tmp.listSync(), isEmpty, reason: '不能把半截包留在缓存里');
    });
  });

  test('install / openUrl 透传到注入的安装器', () async {
    final UpdateService service = buildService();
    final File apk = File('${tmp.path}/app.apk')..writeAsBytesSync(<int>[1]);
    expect(await service.install(apk), isTrue);
    expect(installer.installed?.path, apk.path);
    expect(await service.openUrl('https://a.example.com/x.ipa'), isTrue);
    expect(installer.opened, 'https://a.example.com/x.ipa');
  });

  test('describeUpdateError 保留原始信息', () {
    expect(
      describeUpdateError(TimeoutException('slow')),
      contains('超时'),
    );
    expect(
      describeUpdateError(const SocketException('refused')),
      contains('连不上更新服务器'),
    );
    expect(
      describeUpdateError(const FormatException('bad')),
      contains('格式错误'),
    );
    expect(describeUpdateError(StateError('boom')), contains('更新失败'));
  });
}
