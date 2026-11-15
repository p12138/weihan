// 内置有序更新源（GitHub 主源 + NAS 兜底）与控制面/载荷分离的多源回退测试。
// 全程假网关，不碰真实网络；落盘 override 用 systemTemp 小文件，用例间清干净。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/update_manifest.dart';
import 'package:uyghur_interpreter/update_service.dart';
import 'package:uyghur_interpreter/update_sources.dart';
import 'package:uyghur_interpreter/update_store.dart';

String _manifestJson({String version = '0.6.0'}) => '''
{
  "schema": 1,
  "platform": "android",
  "version": "$version",
  "build": 1,
  "notes": "测试",
  "file": "app.apk",
  "size": 3,
  "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "requiresResign": false
}
''';

/// host 命中 [failHostContains] 的请求抛错，其余返回 [body]：用来模拟
/// 「GitHub 连不上、NAS 通」以及「全部源都连不上」两种场景。
class _RoutingGateway implements UpdateGateway {
  String body = '';
  Object? error;
  String? failHostContains;
  Object failError = const SocketException('offline');
  final List<Uri> requested = <Uri>[];

  @override
  Future<String> getText(Uri uri) async {
    requested.add(uri);
    if (failHostContains != null && uri.host.contains(failHostContains!)) {
      throw failError;
    }
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
  }) async {}
}

void main() {
  setUp(() => UpdateStore.writeBaseUrl(''));
  tearDown(() => UpdateStore.writeBaseUrl(''));

  group('UpdateSources.ordered', () {
    test('顺序：override → GitHub → NAS，GitHub 恒存在', () {
      UpdateStore.writeBaseUrl('https://own.example.com/x');
      final List<UpdateSource> list = UpdateSources(
        githubBase: 'https://gh.example.com/ctl',
        nasBase: 'https://nas.example.com/ctl',
      ).ordered();
      expect(
        list.map((UpdateSource e) => e.id).toList(),
        <String>['override', 'github', 'nas'],
      );
    });

    test('设计 A：GitHub 控制面载荷指向 NAS，凭证不外泄', () {
      final UpdateSource gh = UpdateSources(
        githubBase: 'https://gh.example.com/ctl',
        nasBase: 'https://nas.example.com/ctl',
      ).ordered().firstWhere((UpdateSource e) => e.id == 'github');
      expect(gh.manifestBase, 'https://gh.example.com/ctl');
      expect(gh.payloadBase, 'https://nas.example.com/ctl');
    });

    test('注入 githubPayloadBase 后 GitHub 变成完整源（BUNDLE_ALLOW_PUBLIC）', () {
      final UpdateSource gh = UpdateSources(
        githubBase: 'https://gh.example.com/ctl',
        nasBase: 'https://nas.example.com/ctl',
        githubPayloadBase: 'https://gh.example.com/pkg',
      ).ordered().firstWhere((UpdateSource e) => e.id == 'github');
      expect(gh.payloadBase, 'https://gh.example.com/pkg');
    });

    test('无 dart-define 时仍有内置 fallbackGithubBase 主源', () {
      final List<UpdateSource> list =
          UpdateSources(githubBase: '', nasBase: '').ordered();
      expect(list.length, 1);
      expect(list.single.id, 'github');
      expect(list.single.manifestBase, UpdateSources.fallbackGithubBase);
    });

    test('sourceHosts 含 GitHub+NAS，endpointHosts 不含 GitHub', () {
      final UpdateSources s = UpdateSources(
        githubBase: 'https://gh.example.com/ctl',
        nasBase: 'https://nas.example.com/ctl',
      );
      expect(s.sourceHosts,
          containsAll(<String>['gh.example.com', 'nas.example.com']));
      expect(s.endpointHosts, contains('nas.example.com'));
      expect(s.endpointHosts, isNot(contains('gh.example.com')));
    });
  });

  group('UpdateService.check 多源回退', () {
    test('GitHub 主源失败自动回退 NAS，胜出源与清单地址随结果带出', () async {
      final _RoutingGateway gw = _RoutingGateway()
        ..body = _manifestJson()
        ..failHostContains = 'gh.example.com';
      final UpdateService svc = UpdateService(
        gateway: gw,
        platform: 'android',
        currentVersion: '0.5.0+1',
        sources: UpdateSources(
          githubBase: 'https://gh.example.com/ctl',
          nasBase: 'https://nas.example.com/ctl',
        ),
      );

      final UpdateCheck result = await svc.check();
      expect(result.status, UpdateCheckStatus.available);
      expect(result.source?.id, 'nas');
      expect(
        result.manifestUri.toString(),
        'https://nas.example.com/ctl/latest-android.json',
      );
      expect(result.attempts.length, 1);
      expect(result.attempts.first.source.id, 'github');
      expect(result.attempts.first.kind, UpdateErrorKind.network);
      expect(gw.requested.length, 2);
    });

    test('全部源失败：可读合并错误 + 逐源标签', () async {
      final _RoutingGateway gw = _RoutingGateway()
        ..error = const SocketException('offline');
      final UpdateService svc = UpdateService(
        gateway: gw,
        platform: 'android',
        currentVersion: '0.5.0+1',
        sources: UpdateSources(
          githubBase: 'https://gh.example.com/ctl',
          nasBase: 'https://nas.example.com/ctl',
        ),
      );

      final UpdateCheck result = await svc.check();
      expect(result.status, UpdateCheckStatus.failed);
      expect(result.error, contains('2 个更新源都不可用'));
      expect(result.error, contains('GitHub'));
      expect(result.error, contains('NAS'));
      expect(result.attempts.length, 2);
    });

    test('payloadUri：GitHub 清单胜出但载荷仍从 NAS 取（设计 A）', () {
      final UpdateService svc = UpdateService(
        gateway: _RoutingGateway(),
        platform: 'android',
        sources: UpdateSources(
          githubBase: 'https://gh.example.com/ctl',
          nasBase: 'https://nas.example.com/ctl',
        ),
      );
      final UpdateManifest manifest = UpdateManifest.parse(_manifestJson());
      final UpdateSource gh = svc.effectiveSources
          .ordered()
          .firstWhere((UpdateSource e) => e.id == 'github');
      final Uri ghManifest =
          Uri.parse('https://gh.example.com/ctl/latest-android.json');

      expect(
        svc.payloadUri(manifest, ghManifest, gh).toString(),
        'https://nas.example.com/ctl/app.apk',
      );
      // 不传 source（旧调用）时严格按清单同目录解析，行为与重构前一致。
      expect(
        svc.payloadUri(manifest, ghManifest, null).toString(),
        'https://gh.example.com/ctl/app.apk',
      );
    });
  });

  group('describeFailures', () {
    test('单源保持旧文案', () {
      final SourceAttempt a = SourceAttempt(
        source: UpdateSource.single('https://a.example.com/x'),
        uri: Uri.parse('https://a.example.com/x/latest-android.json'),
        error: const SocketException('refused'),
      );
      expect(describeFailures(<SourceAttempt>[a]),
          contains('连不上更新服务器'));
      expect(describeFailures(<SourceAttempt>[a]),
          isNot(contains('个更新源都不可用')));
    });

    test('空尝试给可读兜底', () {
      expect(describeFailures(<SourceAttempt>[]),
          contains('没有可用的更新源'));
    });
  });
}
