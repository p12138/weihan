import 'dart:io';

import 'package:flutter/services.dart';

/// 把「装包 / 打开链接」这两个动作交给原生层。
///
/// 为什么自己写 MethodChannel 而不用 open_filex / url_launcher：
/// 这两个插件会各自带一套 AndroidX / Pod 约束，而本工程的插件版本是锁死的
/// （见 pubspec 的 dependency_overrides），为了一次安装去动整条工具链不划算。
/// 原生侧只有几十行，两个方法，行为完全可控。
abstract class UpdateInstaller {
  const UpdateInstaller();

  /// 调起系统安装器。Android 走 FileProvider + ACTION_VIEW，
  /// iOS 不支持（未签名包必须重签），实现会返回 false。
  Future<bool> installApk(File apk);

  /// 用系统浏览器打开链接。iOS 用它把用户送去下载页。
  Future<bool> openUrl(String url);
}

/// 走 `weihan/update` 通道的真实实现。
class PlatformUpdateInstaller implements UpdateInstaller {
  const PlatformUpdateInstaller();

  static const MethodChannel _channel = MethodChannel('weihan/update');

  @override
  Future<bool> installApk(File apk) async {
    if (!Platform.isAndroid) {
      return false;
    }
    final bool? ok = await _channel.invokeMethod<bool>(
      'installApk',
      <String, Object>{'path': apk.path},
    );
    return ok ?? false;
  }

  @override
  Future<bool> openUrl(String url) async {
    final bool? ok = await _channel.invokeMethod<bool>(
      'openUrl',
      <String, Object>{'url': url},
    );
    return ok ?? false;
  }
}
