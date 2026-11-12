import 'dart:convert';

/// NAS 上某个平台的最新版本清单。
///
/// 对应 `latest-android.json` / `latest-ios.json`，由 CI 出包后生成：
///
/// ```json
/// {
///   "schema": 1,
///   "platform": "android",
///   "version": "0.5.0",
///   "build": 1,
///   "notes": "修复…",
///   "file": "weihan-selfuse-arm64.apk",
///   "size": 21000000,
///   "sha256": "…",
///   "requiresResign": false,
///   "publishedAt": "2026-11-13T00:30:00Z"
/// }
/// ```
class UpdateManifest {
  const UpdateManifest({
    required this.platform,
    required this.version,
    required this.build,
    required this.notes,
    required this.file,
    required this.size,
    required this.sha256,
    required this.requiresResign,
    this.publishedAt,
  });

  /// 清单格式版本。App 只认这一个：将来改格式时宁可报错让人看到，
  /// 也不要用旧规则去猜一个新文件，猜错的结果是下载到错误的东西。
  static const int supportedSchema = 1;

  /// `android` 或 `ios`。
  final String platform;

  /// 语义化版本，不含 `+build`，例如 `0.5.0`。
  final String version;

  /// 构建号，对应 pubspec 的 `+N`。版本号相同但构建号更大也算有新包。
  final int build;

  /// 更新说明，直接显示在对话框里，允许换行。
  final String notes;

  /// 文件名（不含路径）。实际地址 = 清单地址所在目录 + 该文件名。
  final String file;

  /// 文件字节数，用于显示体积与下载进度。
  final int size;

  /// 小写十六进制 SHA-256，下载完必须逐字比对。
  final String sha256;

  /// iOS 恒为 true：未签名包必须由用户重签，App 只能把文件递出去。
  final bool requiresResign;

  final DateTime? publishedAt;

  /// 解析并校验清单。字段缺失或格式不合法时抛 [FormatException]，
  /// 调用方把异常原文显示出来——「更新失败但不说原因」比不更新更难受。
  static UpdateManifest parse(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('更新清单不是 JSON 对象');
    }

    final int schema = _asInt(decoded['schema'], 'schema');
    if (schema != supportedSchema) {
      throw FormatException(
        '更新清单格式为 $schema，当前 App 只支持 $supportedSchema',
      );
    }

    final String platform = _asString(decoded['platform'], 'platform');
    if (platform != 'android' && platform != 'ios') {
      throw FormatException('未知平台「$platform」');
    }

    final String version = _asString(decoded['version'], 'version');
    final int build = _asInt(decoded['build'] ?? 0, 'build');
    final String file = _asString(decoded['file'], 'file');
    final int size = _asInt(decoded['size'], 'size');
    final String sha256 =
        _asString(decoded['sha256'], 'sha256').toLowerCase();

    if (version.isEmpty) {
      throw const FormatException('version 不能为空');
    }
    if (file.contains('/') || file.contains(r'\')) {
      throw FormatException('file 只能是文件名，不能带路径：「$file」');
    }
    if (size <= 0) {
      throw FormatException('size 必须大于 0，实际为 $size');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('sha256 必须是 64 位十六进制');
    }

    return UpdateManifest(
      platform: platform,
      version: version,
      build: build,
      notes: (decoded['notes'] as String?)?.trim() ?? '',
      file: file,
      size: size,
      sha256: sha256,
      requiresResign: decoded['requiresResign'] == true,
      publishedAt: DateTime.tryParse(
        (decoded['publishedAt'] as String?) ?? '',
      )?.toLocal(),
    );
  }

  /// 相对 [currentVersion] 是否有新版本。
  ///
  /// 只比 `major.minor.patch`，**不比较构建号**：TestFlight 每次上传都要
  /// 换一个新的 build number（Apple 的硬要求），如果把它也算进比较，
  /// 同一个版本号重出包就会在 App 里反复提示「有新版本」——而那种更新
  /// 本来就该由 TestFlight 自己提示。构建号只用于展示。
  bool isNewerThan(String currentVersion) {
    final AppVersion mine = AppVersion.parse(version);
    final AppVersion current = AppVersion.parse(currentVersion);
    final AppVersion mineCore =
        AppVersion(mine.major, mine.minor, mine.patch, 0);
    final AppVersion currentCore =
        AppVersion(current.major, current.minor, current.patch, 0);
    return mineCore.compareTo(currentCore) > 0;
  }

  /// 人类可读的体积，例如 `20.1 MB`。
  String get sizeLabel => formatBytes(size);

  @override
  String toString() =>
      'UpdateManifest($platform $version+$build, $file, $sizeLabel)';
}

/// 把字节数格式化成便于阅读的体积。
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 比较两个版本号，返回负数 / 0 / 正数。
///
/// 支持 `0.5.0`、`0.5.0+1`、`v0.5.0`；比较时先看 major→minor→patch，
/// 全部相同时再看 `+build`。任何一段不是数字都按 0 处理，宁可判成「一样新」
/// 也不要因为一个畸形字符串把更新永久卡死。
int compareAppVersions(String a, String b) {
  return AppVersion.parse(a).compareTo(AppVersion.parse(b));
}

/// 只在本文件内部使用的版本拆解结果。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, this.build);

  factory AppVersion.parse(String raw) {
    String text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    int build = 0;
    final int plus = text.indexOf('+');
    if (plus >= 0) {
      build = int.tryParse(text.substring(plus + 1).trim()) ?? 0;
      text = text.substring(0, plus);
    }
    final List<String> parts = text.split('.');
    int at(int index) {
      if (index >= parts.length) {
        return 0;
      }
      return int.tryParse(parts[index].trim()) ?? 0;
    }

    return AppVersion(at(0), at(1), at(2), build);
  }

  final int major;
  final int minor;
  final int patch;
  final int build;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) {
      return major.compareTo(other.major);
    }
    if (minor != other.minor) {
      return minor.compareTo(other.minor);
    }
    if (patch != other.patch) {
      return patch.compareTo(other.patch);
    }
    return build.compareTo(other.build);
  }
}

String _asString(Object? value, String field) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  throw FormatException('缺少字段 $field');
}

int _asInt(Object? value, String field) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    final int? parsed = int.tryParse(value.trim());
    if (parsed != null) {
      return parsed;
    }
  }
  throw FormatException('字段 $field 必须是整数');
}
