// 远程配置取数 / 落盘 / 通知：configUri、缓存回退、日节流、同步生效。
// 用假网关 + 注入独立临时目录，全程不碰真实网络；不 pump widget。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/remote_config_notifier.dart';
import 'package:uyghur_interpreter/remote_config_service.dart';
import 'package:uyghur_interpreter/remote_config_state.dart';
import 'package:uyghur_interpreter/remote_config_store.dart';
import 'package:uyghur_interpreter/update_service.dart';
import 'package:uyghur_interpreter/update_store.dart';
import 'package:uyghur_interpreter/translation_config.dart';
import 'package:uyghur_interpreter/speech_config.dart';

String _configJson({int version = 5, int silenceMs = 777}) => jsonEncode(
      <String, Object?>{
        'schema': 1,
        'configVersion': version,
        'segmentation': <String, Object?>{'silenceMs': silenceMs},
        'secrets': <String, Object?>{'translation.key': 'SUPER_SECRET'},
      },
    );

class _FakeGateway implements UpdateGateway {
  String body = '';
  Object? error;
  int calls = 0;
  Uri? lastUri;

  @override
  Future<String> getText(Uri uri) async {
    calls += 1;
    lastUri = uri;
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
  late Directory tmp;
  late _FakeGateway gateway;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('weihan_rcfg_test_');
    gateway = _FakeGateway();
  });

  tearDown(() {
    UpdateStore.writeBaseUrl('');
    RemoteConfigNotifier.instance.reset();
    remoteConfigState.reset();
    translationConfig.reset();
    speechConfig.reset();
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  RemoteConfigStore store() => RemoteConfigStore(directory: tmp);
  RemoteConfigService service({RemoteConfigStore? s}) => RemoteConfigService(
        gateway: gateway,
        store: s ?? store(),
      );

  group('RemoteConfigService.configUri', () {
    test('目录 / 显式 json 都取同目录 remote-config.json', () {
      final RemoteConfigService svc = service();
      expect(
        svc.configUri('https://a.example.com/weihan').toString(),
        'https://a.example.com/weihan/remote-config.json',
      );
      expect(
        svc.configUri('https://a.example.com/weihan/').toString(),
        'https://a.example.com/weihan/remote-config.json',
      );
      expect(
        svc
            .configUri('https://a.example.com/weihan/latest-android.json')
            .toString(),
        'https://a.example.com/weihan/remote-config.json',
      );
    });

    test('空地址 / 缺协议抛 UpdateException', () {
      final RemoteConfigService svc = service();
      expect(() => svc.configUri(''), throwsA(isA<UpdateException>()));
      expect(
        () => svc.configUri('a.example.com/weihan'),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('RemoteConfigService.fetch', () {
    test('成功 → fresh，缓存不含密钥', () async {
      gateway.body = _configJson();
      final RemoteConfigFetch result =
          await service().fetch('https://nas.example.com/weihan');
      expect(result.isFresh, isTrue);
      expect(result.source, RemoteConfigSource.fresh);
      expect(result.config.configVersion, 5);
      expect(result.config.segmentation.silenceMs, 777);
      expect(gateway.lastUri.toString(),
          'https://nas.example.com/weihan/remote-config.json');

      final String? cache = store().readCache();
      expect(cache, isNotNull);
      expect(cache, isNot(contains('SUPER_SECRET')));
    });

    test('网络失败且有缓存 → 回退 cache', () async {
      store().writeCache(_configJson(version: 3, silenceMs: 650));
      gateway.error = const SocketException('offline');
      final RemoteConfigFetch result =
          await service().fetch('https://nas.example.com/weihan');
      expect(result.source, RemoteConfigSource.cache);
      expect(result.config.configVersion, 3);
      expect(result.config.segmentation.silenceMs, 650);
      expect(result.error, isNotNull);
    });

    test('网络失败且无缓存 → empty，全字段沿用', () async {
      gateway.error = const SocketException('offline');
      final RemoteConfigFetch result =
          await service().fetch('https://nas.example.com/weihan');
      expect(result.source, RemoteConfigSource.empty);
      expect(result.config.configVersion, 0);
      expect(result.config.secrets, isEmpty);
      expect(result.error, isNotNull);
    });

    test('缓存损坏 → 删缓存并回退 empty', () async {
      store().writeCache('{broken json');
      gateway.error = const SocketException('offline');
      final RemoteConfigFetch result =
          await service().fetch('https://nas.example.com/weihan');
      expect(result.source, RemoteConfigSource.empty);
      expect(store().readCache(), isNull, reason: '坏缓存要删掉，避免反复报错');
    });

    test('服务端返回非法 JSON 也不抛，回退 empty', () async {
      gateway.body = 'not-json';
      final RemoteConfigFetch result =
          await service().fetch('https://nas.example.com/weihan');
      expect(result.source, RemoteConfigSource.empty);
      expect(result.error, isNotNull);
    });
  });

  group('RemoteConfigStore', () {
    test('cache / lastSync / trust 读写与 reset', () {
      final RemoteConfigStore s = store();
      expect(s.readCache(), isNull);
      expect(s.writeCache('hello'), isTrue);
      expect(s.readCache(), 'hello');

      expect(s.readLastSync(), isNull);
      final DateTime now = DateTime(2026, 11, 15, 10);
      expect(s.writeLastSync(now), isTrue);
      expect(s.readLastSync(), now);

      expect(s.readTrustSensitive(), isFalse); // 默认零信任
      expect(s.writeTrustSensitive(true), isTrue);
      expect(s.readTrustSensitive(), isTrue);
      expect(s.writeTrustSensitive(false), isTrue);
      expect(s.readTrustSensitive(), isFalse);

      s.reset();
      expect(s.readCache(), isNull);
      expect(s.readLastSync(), isNull);
      expect(s.readTrustSensitive(), isFalse);
    });
  });

  group('RemoteConfigNotifier', () {
    test('冷启动日节流：24h 内不同步、不请求网络', () async {
      UpdateStore.writeBaseUrl('https://nas.example.com/weihan');
      store().writeLastSync(DateTime.now());
      gateway.body = _configJson();

      final RemoteConfigFetch? result =
          await RemoteConfigNotifier.instance.checkInBackground(
        service: service(),
        store: store(),
      );
      expect(result, isNull);
      expect(gateway.calls, 0);
    });

    test('force 绕过节流，真正取数并把配置应用到 state', () async {
      UpdateStore.writeBaseUrl('https://nas.example.com/weihan');
      store().writeLastSync(DateTime.now());
      gateway.body = _configJson(silenceMs: 820);

      final RemoteConfigFetch? result =
          await RemoteConfigNotifier.instance.checkInBackground(
        service: service(),
        store: store(),
        force: true,
      );
      expect(result, isNotNull);
      expect(result!.isFresh, isTrue);
      expect(gateway.calls, 1);
      expect(remoteConfigState.configVersion, 5);
      expect(remoteConfigState.segmenter.silenceMs, 820);
    });

    test('sync 手动同步生效，状态行能取到版本与时间', () async {
      UpdateStore.writeBaseUrl('https://nas.example.com/weihan');
      gateway.body = _configJson(version: 9);

      final RemoteConfigFetch result = await RemoteConfigNotifier.instance.sync(
        service: service(),
        store: store(),
      );
      expect(result.isFresh, isTrue);
      expect(RemoteConfigNotifier.instance.configVersion, 9);
      expect(RemoteConfigNotifier.instance.lastSync, isNotNull);
      expect(remoteConfigState.configVersion, 9);
    });

    test('未配更新源时 sync 返回可读错误，不请求网络', () async {
      UpdateStore.writeBaseUrl('');
      final RemoteConfigFetch result = await RemoteConfigNotifier.instance.sync(
        service: service(),
        store: store(),
      );
      expect(result.source, RemoteConfigSource.empty);
      expect(result.error, contains('还没有配置'));
      expect(gateway.calls, 0);
    });
  });
}
