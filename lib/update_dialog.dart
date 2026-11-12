import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'glass.dart';
import 'theme.dart';
import 'update_manifest.dart';
import 'update_service.dart';
import 'update_store.dart';

/// 软件更新对话框：检查 → 下载 → 校验 → 交给系统。
///
/// 入口有两个：设置页的「检查更新」，以及启动后横幅点进来（那时已经知道
/// 有新版本，直接传 [manifest]，不再重复请求）。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, this.service, this.manifest});

  final UpdateService? service;
  final UpdateManifest? manifest;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

enum _Phase { checking, upToDate, available, downloading, handedOff, failed }

class _UpdateDialogState extends State<UpdateDialog> {
  late final UpdateService _service;
  _Phase _phase = _Phase.checking;
  UpdateManifest? _manifest;
  Uri? _manifestUri;
  String _error = '';
  double _progress = 0;
  int _received = 0;
  int _total = 0;

  bool get _isAndroid => _service.platform == 'android';

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? UpdateService();
    final UpdateManifest? initial = widget.manifest;
    if (initial != null) {
      _manifest = initial;
      _manifestUri = _safeManifestUri();
      _phase = _Phase.available;
    } else {
      unawaited(_check());
    }
  }

  /// 清单地址可能因为用户填错而抛异常；这里不把它当致命错误，
  /// 真正请求时会再用同一套规则报一次，界面能显示具体原因。
  Uri? _safeManifestUri() {
    try {
      return _service.manifestUri(UpdateStore.readBaseUrl());
    } on Object {
      return null;
    }
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = '';
    });
    final UpdateCheck result = await _service.check(UpdateStore.readBaseUrl());
    if (!mounted) {
      return;
    }
    if (result.status == UpdateCheckStatus.available) {
      setState(() {
        _manifest = result.manifest;
        _manifestUri = _safeManifestUri();
        _phase = _Phase.available;
      });
      return;
    }
    if (result.status == UpdateCheckStatus.upToDate) {
      setState(() => _phase = _Phase.upToDate);
      return;
    }
    setState(() {
      _phase = _Phase.failed;
      _error = result.error ?? '未知错误';
    });
  }

  Future<void> _downloadAndInstall() async {
    final UpdateManifest? manifest = _manifest;
    final Uri? manifestUri = _manifestUri;
    if (manifest == null || manifestUri == null) {
      setState(() {
        _phase = _Phase.failed;
        _error = '没有可用的更新清单，请重新检查';
      });
      return;
    }

    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _received = 0;
      _total = manifest.size;
      _error = '';
    });

    try {
      final File file = await _service.download(
        manifest,
        manifestUri,
        onProgress: (int received, int total) {
          if (!mounted) {
            return;
          }
          final int size = total > 0 ? total : manifest.size;
          setState(() {
            _received = received;
            _total = size;
            _progress = size > 0
                ? (received / size).clamp(0.0, 1.0).toDouble()
                : 0;
          });
        },
      );
      if (!mounted) {
        return;
      }

      if (_isAndroid) {
        final bool accepted = await _service.install(file);
        if (!mounted) {
          return;
        }
        setState(() {
          _phase = _Phase.handedOff;
          _error = accepted ? '' : '系统没有接受安装请求';
        });
        return;
      }

      // iOS 装不了未签名包，只能把用户送到下载页，让他自己重签。
      final String url =
          _service.downloadPage(manifest, manifestUri).toString();
      final bool opened = await _service.openUrl(url);
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _Phase.handedOff;
        _error = opened ? '' : '打不开浏览器，请手动下载：$url';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _Phase.failed;
        _error = describeUpdateError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: GlassPanel(
        corner: 26,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _header(),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: _body(),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: _actions(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 8, 14),
      child: Row(
        children: <Widget>[
          Icon(Icons.system_update_alt, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '软件更新',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
            color: AppColors.inkMuted,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final UpdateManifest? manifest = _manifest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '当前版本 ${_service.currentVersion}',
          style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
        ),
        if (manifest != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '最新版本 ${manifest.version}+${manifest.build} · ${manifest.sizeLabel}',
            key: const ValueKey<String>('update-latest-version'),
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryDeep,
            ),
          ),
          if (manifest.publishedAt != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '发布于 ${_formatDate(manifest.publishedAt!)}',
              style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
          ],
          if (manifest.notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: Text(
                manifest.notes,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: AppColors.ink,
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),
        _status(),
      ],
    );
  }

  Widget _status() {
    switch (_phase) {
      case _Phase.checking:
        return Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '正在检查更新…',
              style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
            ),
          ],
        );
      case _Phase.upToDate:
        return Text(
          '已经是最新版本，不需要更新。',
          key: const ValueKey<String>('update-up-to-date'),
          style: TextStyle(fontSize: 13, height: 1.6, color: AppColors.inkMuted),
        );
      case _Phase.available:
        return Text(
          _isAndroid
              ? '下载完成后会交给系统安装器，按提示允许「安装未知应用」即可覆盖升级。'
              : 'iOS 的自用包未签名，无法在应用内直接安装。点下面按钮打开下载页，'
                  '用 Sideloadly / 爱思助手 / Xcode 重签后安装。',
          key: const ValueKey<String>('update-hint'),
          style: TextStyle(fontSize: 12.5, height: 1.6, color: AppColors.inkMuted),
        );
      case _Phase.downloading:
        final int percent = (_progress * 100).round();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 8,
                backgroundColor: AppColors.primarySoft,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '正在下载 $percent% · ${formatBytes(_received)} / ${formatBytes(_total)}',
              style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
          ],
        );
      case _Phase.handedOff:
        return Text(
          _error.isEmpty
              ? (_isAndroid
                  ? '已交给系统安装器，请在弹出的窗口里确认安装。'
                  : '已打开下载页，重签后即可安装。')
              : _error,
          key: const ValueKey<String>('update-handed-off'),
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: _error.isEmpty ? AppColors.inkMuted : AppColors.coral,
          ),
        );
      case _Phase.failed:
        return Text(
          _error,
          key: const ValueKey<String>('update-error'),
          style: TextStyle(fontSize: 12.5, height: 1.6, color: AppColors.coral),
        );
    }
  }

  Widget _actions() {
    switch (_phase) {
      case _Phase.checking:
        return const SizedBox(height: 40);
      case _Phase.upToDate:
        return _button('知道了', () => Navigator.of(context).pop());
      case _Phase.available:
        return Row(
          children: <Widget>[
            Expanded(
              child: _button(
                '以后再说',
                () => Navigator.of(context).pop(),
                filled: false,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: _button(
                _isAndroid ? '下载并安装' : '打开下载页',
                _downloadAndInstall,
              ),
            ),
          ],
        );
      case _Phase.downloading:
        return _button('下载中…', null);
      case _Phase.handedOff:
        return _button('完成', () => Navigator.of(context).pop());
      case _Phase.failed:
        return Row(
          children: <Widget>[
            Expanded(
              child: _button(
                '关闭',
                () => Navigator.of(context).pop(),
                filled: false,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: _button('重试', () {
                if (_manifest == null) {
                  unawaited(_check());
                } else {
                  unawaited(_downloadAndInstall());
                }
              }),
            ),
          ],
        );
    }
  }

  Widget _button(String label, VoidCallback? onPressed, {bool filled = true}) {
    final bool enabled = onPressed != null;
    return SizedBox(
      height: 44,
      child: filled
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor: AppColors.primarySoft,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: enabled ? Colors.white : AppColors.inkMuted,
                ),
              ),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.line),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(fontSize: 14, color: AppColors.inkMuted),
              ),
            ),
    );
  }

  String _formatDate(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}
