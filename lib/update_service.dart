import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'app_version.dart';
import 'update_installer.dart';
import 'update_manifest.dart';
import 'update_sources.dart';

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
  const UpdateCheck.upToDate({
    required this.currentVersion,
    this.source,
    this.manifestUri,
    this.attempts = const <SourceAttempt>[],
  })  : status = UpdateCheckStatus.upToDate,
        manifest = null,
        error = null;

  const UpdateCheck.available({
    required this.currentVersion,
    required this.manifest,
    this.source,
    this.manifestUri,
    this.attempts = const <SourceAttempt>[],
  })  : status = UpdateCheckStatus.available,
        error = null;

  const UpdateCheck.failed({
    required this.currentVersion,
    required this.error,
    this.source,
    this.manifestUri,
    this.attempts = const <SourceAttempt>[],
  })  : status = UpdateCheckStatus.failed,
        manifest = null;

  final UpdateCheckStatus status;
  final String currentVersion;
  final UpdateManifest? manifest;
  final String? error;

  /// 胜出的更新源。多源回退时，载荷（APK）地址必须用它的 [payloadBase]
  /// 而不是清单地址——设计 A 下 GitHub 清单胜出、载荷仍在 NAS。
  final UpdateSource? source;

  /// 胜出源实际取到的清单地址（下载对话框据此拼同目录文件，避免回退后仍用主源）。
  final Uri? manifestUri;

  /// 走到胜出前的失败尝试，供错误说明与测试核对「确实回退过」。
  final List<SourceAttempt> attempts;
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

/// 更新检查失败的粗分类。给 [SourceAttempt] 留原始异常的分类，方便界面与测试
/// 区分「网络不通（该回退）」和「清单内容错（服务器数据问题）」。
enum UpdateErrorKind { network, config, data, other }

/// 在 [describeUpdateError] 把异常拍平成字符串之前，先按类型分好类。
UpdateErrorKind classifyUpdateError(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException) {
    return UpdateErrorKind.network;
  }
  if (error is UpdateException) {
    return UpdateErrorKind.config;
  }
  if (error is FormatException) {
    return UpdateErrorKind.data;
  }
  return UpdateErrorKind.other;
}

/// 某个源的一次失败尝试：保留原始异常，附带可读的「源标签：原因」。
class SourceAttempt {
  const SourceAttempt({
    required this.source,
    required this.uri,
    required this.error,
  });

  final UpdateSource source;
  final Uri? uri;
  final Object error;

  UpdateErrorKind get kind => classifyUpdateError(error);

  String describe() => '${source.label}：${describeUpdateError(error)}';
}

/// [resolveFromSources] 的返回值：要么第一个成功源连同胜出源 / URI，要么全失败。
class SourceFetch<T> {
  const SourceFetch.success({
    required this.value,
    required this.source,
    required this.uri,
    required this.attempts,
  })  : ok = true,
        error = null;

  const SourceFetch.failure({
    required this.attempts,
    required this.error,
  })  : ok = false,
        value = null,
        source = null,
        uri = null;

  final bool ok;
  final T? value;
  final UpdateSource? source;
  final Uri? uri;
  final List<SourceAttempt> attempts;
  final String? error;
}

/// 逐源尝试：取文本 → 解析，第一个成功即胜出，记录其 [source] 与 [uri]；
/// 任一源失败都记一条 [SourceAttempt] 后继续下一个。全失败才返回合并错误。
///
/// 泛型 [T] 让整包清单（[UpdateManifest]）与远程配置共用同一套回退逻辑，
/// 不把 [describeUpdateError] 的拍平结果当成原始异常丢掉。
Future<SourceFetch<T>> resolveFromSources<T>({
  required List<UpdateSource> sources,
  required Uri Function(UpdateSource source) uriOf,
  required Future<String> Function(Uri uri) getText,
  required T Function(String body) parse,
}) async {
  final List<SourceAttempt> attempts = <SourceAttempt>[];
  for (final UpdateSource source in sources) {
    Uri? uri;
    try {
      uri = uriOf(source);
      final String body = await getText(uri);
      final T value = parse(body);
      return SourceFetch<T>.success(
        value: value,
        source: source,
        uri: uri,
        attempts: attempts,
      );
    } on Object catch (error) {
      attempts.add(SourceAttempt(source: source, uri: uri, error: error));
    }
  }
  return SourceFetch<T>.failure(
    attempts: attempts,
    error: describeFailures(attempts),
  );
}

/// 合并所有源的失败原因。单源时保持旧文案（现有 `check('…')` 单测不受影响），
/// 多源时逐源带标签，用户一眼能看出「GitHub 连不上、NAS 也连不上」。
String describeFailures(List<SourceAttempt> attempts) {
  if (attempts.isEmpty) {
    return '没有可用的更新源';
  }
  if (attempts.length == 1) {
    return describeUpdateError(attempts.first.error);
  }
  final String lines = attempts
      .map((SourceAttempt a) => '· ${a.describe()}')
      .join('\n');
  return '${attempts.length} 个更新源都不可用：\n$lines';
}

/// 检查 → 下载 → 校验 → 交给系统安装，整条更新链路。
class UpdateService {
  UpdateService({
    this.gateway = const DartIoUpdateGateway(),
    this.installer = const PlatformUpdateInstaller(),
    this.currentVersion = kAppVersion,
    String? platform,
    Directory? downloadDir,
    UpdateSources? sources,
  })  : platform = platform ?? (Platform.isAndroid ? 'android' : 'ios'),
        _downloadDir = downloadDir,
        _sources = sources;

  final UpdateGateway gateway;
  final UpdateInstaller installer;
  final String currentVersion;

  /// 显式注入的有序源（单测用）。生产为 null → 用内置
  /// [UpdateSources.instance]（GitHub 主源 + NAS 兜底）。
  final UpdateSources? _sources;

  UpdateSources get effectiveSources =>
      _sources ?? UpdateSources.instance;

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
    final Uri base = parseUpdateBase(baseUrl);
    // 行为与重构前完全一致：显式给了某个 .json 就原样用。
    if (base.path.endsWith('.json')) {
      return base;
    }
    final String dir = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '${dir}latest-$platform.json');
  }

  /// 查一次最新版本。
  ///
  /// [singleBase] 不为 null 时只查这一个地址（保留旧调用与单测的「单源」语义）；
  /// 不传（生产路径）则走内置有序源 [effectiveSources]：GitHub 主源优先，
  /// 走不通自动回退 NAS。任何异常都收敛成 [UpdateCheckStatus.failed] + 可读原因。
  Future<UpdateCheck> check([String? singleBase]) async {
    final List<UpdateSource> sources = singleBase != null
        ? <UpdateSource>[UpdateSource.single(singleBase)]
        : effectiveSources.ordered();

    final SourceFetch<UpdateManifest> fetched =
        await resolveFromSources<UpdateManifest>(
      sources: sources,
      uriOf: (UpdateSource s) => manifestUri(s.manifestBase),
      getText: gateway.getText,
      parse: (String body) {
        final UpdateManifest manifest = UpdateManifest.parse(body);
        if (manifest.platform != platform) {
          throw UpdateException(
            '清单是 ${manifest.platform} 的，当前设备是 $platform',
          );
        }
        return manifest;
      },
    );

    if (!fetched.ok) {
      return UpdateCheck.failed(
        currentVersion: currentVersion,
        error: fetched.error ?? '更新检查失败',
        attempts: fetched.attempts,
      );
    }
    final UpdateManifest manifest = fetched.value!;
    if (manifest.isNewerThan(currentVersion)) {
      return UpdateCheck.available(
        currentVersion: currentVersion,
        manifest: manifest,
        source: fetched.source,
        manifestUri: fetched.uri,
        attempts: fetched.attempts,
      );
    }
    return UpdateCheck.upToDate(
      currentVersion: currentVersion,
      source: fetched.source,
      manifestUri: fetched.uri,
      attempts: fetched.attempts,
    );
  }

  /// 下载并校验。校验不过就删掉文件并抛异常——宁可让用户重下，
  /// 也不能把一个半截或串了内容的包递给安装器。
  Future<File> download(
    UpdateManifest manifest,
    Uri manifestUri, {
    UpdateSource? source,
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
    final Uri fileUri = payloadUri(manifest, manifestUri, source);

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

  /// 载荷（APK / IPA）地址。
  ///
  /// [source] 不为 null（生产、设计 A）时用它的 [UpdateSource.payloadBase]：
  /// GitHub 清单胜出时，载荷仍指向 NAS，凭证不外泄。[source] 为 null
  /// （旧调用 / 现有单测）时严格按清单同目录解析，行为与重构前一致。
  Uri payloadUri(
    UpdateManifest manifest,
    Uri manifestUri,
    UpdateSource? source,
  ) {
    final Uri base = source != null
        ? parseUpdateBase(source.payloadBase)
        : manifestUri;
    return base.replace(
      path: '${updateDirectoryOf(base)}${manifest.file}',
    );
  }

  /// iOS 的下载页地址：清单文件旁边（或胜出源载荷基址下）那个 IPA。
  Uri downloadPage(
    UpdateManifest manifest,
    Uri manifestUri, {
    UpdateSource? source,
  }) =>
      payloadUri(manifest, manifestUri, source);
}

/// 某个 URI 所在的目录（以 `/` 结尾）。清单 / 基址都据此拼同目录文件名。
String updateDirectoryOf(Uri uri) {
  final String path = uri.path;
  final int slash = path.lastIndexOf('/');
  if (path.endsWith('.json')) {
    return slash >= 0 ? path.substring(0, slash + 1) : '/';
  }
  return path.endsWith('/') ? path : '$path/';
}

/// 校验并解析「更新源地址」基址，供整包清单与远程配置共用。
///
/// 空 / 非法 URL / 缺协议或 host 都给可读错误。抽出来是为了让
/// `remote_config_service.dart` 的 `configUri` 与 `manifestUri` 用同一套
/// 校验口径，而不是各写一份 `Uri.parse` + 错误文案。
Uri parseUpdateBase(String baseUrl) {
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
  return base;
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
