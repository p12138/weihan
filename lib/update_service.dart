import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'app_version.dart';
import 'update_installer.dart';
import 'update_manifest.dart';

/// 一次更新检查的三种结局。
enum UpdateCheckStatus {
  /// 已经是最新，不需要打扰用户。
  upToDate,

  /// 服务器上有新包。
  available,

  /// 检查失败。必须保留原始原因，界面直接显示。
  failed,
}

/// 检查结果。用可空字段而不是抛异常：检查失败是常态（出门没网、NAS 重启），
/// 不该让调用方到处写 try/catch。
class UpdateCheck {
  const UpdateCheck.upToDate({required this.currentVersion})
      : status = UpdateCheckStatus.upToDate,
        manifest = null,
        error = null;

  const UpdateCheck.available({
    required this.currentVersion,
    required UpdateManifest manifest,
  })  : status = UpdateCheckStatus.available,
        manifest = manifest,
        error = null;

  const UpdateCheck.failed({
    required this.currentVersion,
    required String error,
  })  : status = UpdateCheckStatus.failed,
        manifest = null,
        error = error;

  final UpdateCheckStatus status;
  final String currentVersion;
  final UpdateManifest? manifest;
  final String? error;
}

/// 更新链路的可读异常。`toString()` 只返回消息，界面直接显示即可。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 只做「取文本 / 下载到文件」两件事，便于单测替换成假实现。
abstract class UpdateGateway {
  const UpdateGateway();

  Future<String> getText(Uri uri);

  Future<void> downloadTo(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  });
}

/// dart:io 实现。所有等待都有上限：NAS 掉线时不能让「检查更新」永远转圈。
class DartIoUpdateGateway implements UpdateGateway {
  const DartIoUpdateGateway({
    this.connectTimeout = const Duration(seconds: 8),
    this.readTimeout = const Duration(seconds: 20),
  });

  final Duration connectTimeout;
  final Duration readTimeout;

  @override
  Future<String> getText(Uri uri) async {
    final HttpClient client = HttpClient()..connectionTimeout = connectTimeout;
    // 清单必须拿最新的：NAS 或中间代理缓存住旧版本会让「明明发了新版却查不到」。
    try {
      final HttpClientRequest request =
          await client.getUrl(uri).timeout(connectTimeout);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final HttpClientResponse response =
          await request.close().timeout(readTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException('更新源返回 HTTP ${response.statusCode}');
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(readTimeout);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> downloadTo(
    Uri uri,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = connectTimeout;
    IOSink? sink;
    try {
      final HttpClientRequest request =
          await client.getUrl(uri).timeout(connectTimeout);
      final HttpClientResponse response =
          await request.close().timeout(readTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException('下载失败，服务器返回 HTTP ${response.statusCode}');
      }
      if (!target.parent.existsSync()) {
        target.parent.createSync(recursive: true);
      }
      sink = target.openWrite();
      final int total = response.contentLength;
      int received = 0;
      await for (final List<int> chunk in response.timeout(readTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }
}

/// 检查 → 下载 → 校验 → 交给系统安装，整条更新链路。
class UpdateService {
  UpdateService({
    this.gateway = const DartIoUpdateGateway(),
    this.installer = const PlatformUpdateInstaller(),
    this.currentVersion = kAppVersion,
    String? platform,
    Directory? downloadDir,
  })  : platform = platform ?? (Platform.isAndroid ? 'android' : 'ios'),
        _downloadDir = downloadDir;

  final UpdateGateway gateway;
  final UpdateInstaller installer;
  final String currentVersion;

  /// `android` 或 `ios`，决定去取哪份清单。
  final String platform;

  /// 下载目录。测试里传独立临时目录，避免与并行用例抢同一个文件夹。
  final Directory? _downloadDir;

  Directory get downloadDir =>
      _downloadDir ??
      Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}weihan-update',
      );

  /// 清单地址。传目录则补 `latest-<platform>.json`，传完整 `.json` 则原样使用，
  /// 便于临时指向某个测试清单。
  Uri manifestUri(String baseUrl) {
    final String text = baseUrl.trim();
    if (text.isEmpty) {
      throw const UpdateException('还没有配置更新源地址');
    }
    final Uri base;
    try {
      base = Uri.parse(text);
    } on FormatException {
      throw UpdateException('更新源地址不是合法 URL：$text');
    }
    if (!base.hasScheme || base.host.isEmpty) {
      throw UpdateException('更新源地址不完整（要带 http:// 或 https://）：$text');
    }
    if (base.path.endsWith('.json')) {
      return base;
    }
    final String dir = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '${dir}latest-$platform.json');
  }

  /// 查一次最新版本。任何异常都转成 [UpdateCheckStatus.failed] + 原文。
  Future<UpdateCheck> check(String baseUrl) async {
    try {
      final Uri uri = manifestUri(baseUrl);
      final String body = await gateway.getText(uri);
      final UpdateManifest manifest = UpdateManifest.parse(body);
      if (manifest.platform != platform) {
        throw UpdateException(
          '清单是 ${manifest.platform} 的，当前设备是 $platform',
        );
      }
      if (manifest.isNewerThan(currentVersion)) {
        return UpdateCheck.available(
          currentVersion: currentVersion,
          manifest: manifest,
        );
      }
      return UpdateCheck.upToDate(currentVersion: currentVersion);
    } on Object catch (error) {
      return UpdateCheck.failed(
        currentVersion: currentVersion,
        error: describeUpdateError(error),
      );
    }
  }

  /// 下载并校验。校验不过就删掉文件并抛异常——宁可让用户重下，
  /// 也不能把一个半截或串了内容的包递给安装器。
  Future<File> download(
    UpdateManifest manifest,
    Uri manifestUri, {
    void Function(int received, int total)? onProgress,
  }) async {
    final Directory dir = downloadDir;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    // 只留当前要装的这一个，避免旧包把手机缓存越占越大。
    for (final FileSystemEntity entity in dir.listSync()) {
      try {
        entity.deleteSync(recursive: true);
      } on Object {
        continue;
      }
    }

    final File target = File('${dir.path}${Platform.pathSeparator}${manifest.file}');
    final Uri fileUri = manifestUri.replace(
      path: '${manifestUri.path.substring(0, manifestUri.path.lastIndexOf('/') + 1)}${manifest.file}',
    );

    try {
      await gateway.downloadTo(fileUri, target, onProgress: onProgress);
      final String actual = await sha256OfFile(target);
      if (actual != manifest.sha256) {
        throw UpdateException(
          '校验失败：期望 ${manifest.sha256.substring(0, 12)}…，'
          '实际 ${actual.substring(0, 12)}…（文件可能只下了一半）',
        );
      }
      return target;
    } on Object {
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } on Object {
          // 删不掉也不影响判断，下次下载前会整目录清空。
        }
      }
      rethrow;
    }
  }

  /// 把已校验的包交给系统。Android 会弹出「是否安装」；iOS 恒为 false。
  Future<bool> install(File apk) => installer.installApk(apk);

  Future<bool> openUrl(String url) => installer.openUrl(url);

  /// iOS 的下载页地址：清单文件旁边那个 IPA。
  Uri downloadPage(UpdateManifest manifest, Uri manifestUri) {
    return manifestUri.replace(
      path: '${manifestUri.path.substring(0, manifestUri.path.lastIndexOf('/') + 1)}${manifest.file}',
    );
  }
}

/// 把各种异常翻译成能看懂的一句话，保留原始信息，不吞细节。
String describeUpdateError(Object error) {
  if (error is UpdateException) {
    return error.message;
  }
  if (error is TimeoutException) {
    final int seconds = error.duration?.inSeconds ?? 0;
    return '请求超时（${seconds}s），检查手机网络或 NAS 是否在线';
  }
  if (error is SocketException) {
    return '连不上更新服务器：${error.message}';
  }
  if (error is HandshakeException) {
    return 'HTTPS 证书校验失败：${error.message}';
  }
  if (error is FormatException) {
    return '更新清单格式错误：${error.message}';
  }
  if (error is HttpException) {
    return 'HTTP 错误：${error.message}';
  }
  if (error is FileSystemException) {
    return '读写安装包失败：${error.message}';
  }
  return '更新失败：$error';
}

/// 计算文件 SHA-256。分块读取，避免把 25 MB 一次性读进内存。
Future<String> sha256OfFile(File file) async {
  final _DigestCollector collector = _DigestCollector();
  final ByteConversionSink input = sha256.startChunkedConversion(collector);
  await for (final List<int> chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  final Digest? digest = collector.value;
  if (digest == null) {
    throw const UpdateException('计算 SHA-256 失败（文件可能为空）');
  }
  return digest.toString();
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
