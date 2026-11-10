import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'bundled_config.dart';
import 'conversation.dart';
import 'default_speech.dart';
import 'default_translator.dart';
import 'device_audio.dart';
import 'speech_config.dart';
import 'speech_pipeline.dart';
import 'translation_config.dart';

/// 对话页：文字互译、语音互译、方向切换、双语气泡（维文自动 RTL）。
class ConversationPage extends StatefulWidget {
  ConversationPage({
    super.key,
    Translator? translator,
    this.speech = const ConfigurableSpeechPort(),
    this.audio,
  }) : translator = translator ?? buildDefaultTranslator();

  final Translator translator;
  final SpeechPort speech;

  /// 可注入的录音 / 播放端口，测试里用假实现避免触碰平台通道。
  final AudioPort? audio;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final TextEditingController _controller = TextEditingController();
  ConversationState _state = const ConversationState();
  String _notice = '';
  bool _busy = false;
  bool _recording = false;
  int _nextId = 0;
  AudioPort? _audioPort;
  late final SpeechPipeline _pipeline = SpeechPipeline(
    speech: widget.speech,
    translator: widget.translator,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 只有真正用到麦克风时才创建平台插件实例，widget 测试不会触碰它。
  AudioPort _audio() {
    _audioPort ??= widget.audio ?? DeviceAudioPort();
    return _audioPort!;
  }

  Message _newMessage(String text, Language language, bool isMine) {
    final Message message = Message(
      id: _nextId,
      text: text,
      language: language,
      isMine: isMine,
    );
    _nextId += 1;
    return message;
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty || _busy) {
      return;
    }
    final TranslationDirection direction = _state.direction;
    setState(() {
      _busy = true;
      _notice = '';
      _state = _state.add(_newMessage(text, direction.source, true));
    });
    _controller.clear();

    final Translation result = await widget.translator.translate(
      text,
      direction.source,
      direction.target,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      if (result.found) {
        _state = _state.add(
          _newMessage(result.text, direction.target, false),
        );
        _notice = result.isDemo
            ? '演示词库命中 · 配置小牛翻译后可翻译任意句子'
            : '由 ${result.provider} 返回';
      } else {
        final String diagnostic = translationConfig.lastDiagnostic.trim();
        final String short = _brief(diagnostic);
        _notice = translationConfig.hasCloudConfig
            ? (short.isEmpty
                ? '云端翻译未返回译文 · 请检查 APPID / API-KEY / 网络'
                : '云端失败 · $short')
            : '演示词库未收录这句 · 配置小牛翻译后可翻译任意句子';
      }
    });
  }

  Future<void> _tapVoice() async {
    if (_recording) {
      await _finishVoice();
      return;
    }
    if (_busy) {
      return;
    }
    try {
      final bool granted = await _audio().hasPermission();
      if (!granted) {
        if (!mounted) {
          return;
        }
        setState(() => _notice = '需要麦克风权限才能在系统设置里开启录音');
        return;
      }
      await _audio().startRecord();
      if (!mounted) {
        return;
      }
      setState(() {
        _recording = true;
        _notice = '正在录音 · 说完再点一次按钮';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _notice = '无法开始录音：${_brief(error.toString())}');
    }
  }

  Future<void> _finishVoice() async {
    setState(() {
      _recording = false;
      _busy = true;
      _notice = '正在识别与翻译…';
    });
    final TranslationDirection direction = _state.direction;
    try {
      final Uint8List pcm = await _audio().stopRecord();
      final SpeechTurn turn = await _pipeline.run(pcm, direction);
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _state = _state.add(_newMessage(turn.heard, direction.source, true));
        if (turn.translation.found) {
          _state = _state.add(
            _newMessage(turn.translation.text, direction.target, false),
          );
          _notice = '识别到「${turn.heard}」· 由 ${turn.translation.provider} 翻译';
        } else {
          _notice = '识别到「${turn.heard}」· 但未返回译文';
        }
      });
      if (turn.hasAudio) {
        await _audio().play(turn.audio);
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      final String diagnostic = speechConfig.lastDiagnostic.trim();
      setState(() {
        _busy = false;
        _notice = '语音失败 · ${diagnostic.isEmpty ? _brief(error.toString()) : _brief(diagnostic)}';
      });
    }
  }

  Future<void> _speak(String text, Language language) async {
    try {
      final Uint8List audio = await widget.speech.speak(text, language);
      if (audio.isNotEmpty) {
        await _audio().play(audio);
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      final String diagnostic = speechConfig.lastDiagnostic.trim();
      setState(() {
        _notice = '朗读失败 · ${diagnostic.isEmpty ? _brief(error.toString()) : _brief(diagnostic)}';
      });
    }
  }

  static String _brief(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  void _flipDirection() {
    setState(() {
      _state = _state.flip();
      _notice = '';
    });
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => const _SettingsDialog(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _notice = translationConfig.hasCloudConfig
          ? '云端翻译已启用 · 现在可以翻译任意句子'
          : '云端翻译已关闭 · 仅使用本地演示词库';
    });
  }

  @override
  Widget build(BuildContext context) {
    final TranslationDirection direction = _state.direction;
    final bool speechReady = widget.speech.isAvailable;
    return Scaffold(
      appBar: AppBar(
        title: const Text('维汉互译'),
        actions: <Widget>[
          IconButton(
            tooltip: '云端翻译与语音设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: '切换翻译方向',
            onPressed: _flipDirection,
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ModeBanner(
            direction: direction,
            speechAvailable: speechReady,
            cloudEnabled: translationConfig.hasCloudConfig,
          ),
          Expanded(
            child: _buildList(
              onSpeak: speechReady
                  ? (String text, Language language) {
                      _speak(text, language);
                    }
                  : null,
            ),
          ),
          if (_notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _notice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          _buildComposer(direction, speechReady),
        ],
      ),
    );
  }

  Widget _buildList({SpeakCallback? onSpeak}) {
    if (_state.messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '输入一句中文或维文试试，例如「你好」',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _state.messages.length,
      itemBuilder: (BuildContext context, int index) => MessageBubble(
        message: _state.messages[index],
        onSpeak: onSpeak,
      ),
    );
  }

  Widget _buildComposer(TranslationDirection direction, bool speechReady) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textDirection: direction.source.isRtl
                        ? TextDirection.rtl
                        : TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: '输入${direction.source.label}',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (String value) {
                      _submit();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '发送',
                  onPressed: _busy || _recording
                      ? null
                      : () {
                          _submit();
                        },
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: speechReady
                  ? '点一下开始说话，说完再点一下结束'
                  : '先在设置里填讯飞语音凭证',
              child: TextButton.icon(
                onPressed: speechReady
                    ? () {
                        _tapVoice();
                      }
                    : null,
                icon: Icon(_recording ? Icons.mic : Icons.mic_none),
                label: Text(
                  _recording
                      ? '正在录音 · 点击结束'
                      : (speechReady
                          ? '点击说话 · 再点结束'
                          : '按住说话 · 待接入'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef SpeakCallback = void Function(String text, Language language);

class _ModeBanner extends StatelessWidget {
  const _ModeBanner({
    required this.direction,
    required this.speechAvailable,
    required this.cloudEnabled,
  });

  final TranslationDirection direction;
  final bool speechAvailable;
  final bool cloudEnabled;

  @override
  Widget build(BuildContext context) {
    final String speechLabel = speechAvailable ? '已接入' : '待接入';
    final String modeLabel = cloudEnabled ? '云端翻译' : '演示词库';
    final String label =
        '${direction.source.label} → ${direction.target.label} · $modeLabel · 语音$speechLabel';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// 单条消息气泡，按语言自动选择排版方向；译文气泡可单独朗读。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onSpeak,
  });

  final Message message;
  final SpeakCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final bool rtl = message.language.isRtl;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget bubble = Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        color: message.isMine
            ? colors.primaryContainer
            : colors.secondaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(16)),
      ),
      child: Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: Text(
          message.text,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: rtl ? TextAlign.right : TextAlign.left,
        ),
      ),
    );
    final SpeakCallback? speak = onSpeak;
    if (message.isMine || speak == null) {
      return Align(
        alignment: message.isMine
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: bubble,
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(child: bubble),
          IconButton(
            tooltip: '朗读这句译文',
            onPressed: () => speak(message.text, message.language),
            icon: const Icon(Icons.volume_up),
          ),
        ],
      ),
    );
  }
}

/// 云端翻译 + 语音设置。密钥只保存在进程内存里，不落盘、不入库、不随包分发。
/// 切换服务商 / 填完语音凭证后，翻译链与语音链下一次调用立即按新配置重建。
class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _appIdController;
  late final TextEditingController _keyController;
  late final TextEditingController _regionController;
  late final TextEditingController _endpointController;
  late final TextEditingController _xfAppIdController;
  late final TextEditingController _xfApiKeyController;
  late final TextEditingController _xfApiSecretController;
  late final TextEditingController _xfUgVcnController;
  late final TextEditingController _xfZhVcnController;
  late final TextEditingController _xfEndpointController;
  late TranslationProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = translationConfig.provider;
    // 自带凭证的包里绝不能把内置密钥明文回填到输入框（手机屏幕会直接显示）。
    final bool bundled = kHasBundledCredentials;
    _appIdController =
        TextEditingController(text: bundled ? '' : translationConfig.appId);
    _keyController =
        TextEditingController(text: bundled ? '' : translationConfig.key);
    _regionController = TextEditingController(text: translationConfig.region);
    _endpointController =
        TextEditingController(text: translationConfig.endpoint);
    _xfAppIdController =
        TextEditingController(text: bundled ? '' : speechConfig.appId);
    _xfApiKeyController =
        TextEditingController(text: bundled ? '' : speechConfig.apiKey);
    _xfApiSecretController =
        TextEditingController(text: bundled ? '' : speechConfig.apiSecret);
    _xfUgVcnController = TextEditingController(text: speechConfig.ugVcn);
    _xfZhVcnController = TextEditingController(text: speechConfig.zhVcn);
    _xfEndpointController =
        TextEditingController(text: speechConfig.endpoint);
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _keyController.dispose();
    _regionController.dispose();
    _endpointController.dispose();
    _xfAppIdController.dispose();
    _xfApiKeyController.dispose();
    _xfApiSecretController.dispose();
    _xfUgVcnController.dispose();
    _xfZhVcnController.dispose();
    _xfEndpointController.dispose();
    super.dispose();
  }

  void _save() {
    // 内置凭证模式下密钥输入框初始为空，留空代表「沿用内置值」；
    // 只有用户主动输入才覆盖。否则一进设置页点保存就会把内置凭证清空。
    final bool bundled = kHasBundledCredentials;
    translationConfig.provider = _provider;
    if (!bundled || _appIdController.text.trim().isNotEmpty) {
      translationConfig.appId = _appIdController.text.trim();
    }
    if (!bundled || _keyController.text.trim().isNotEmpty) {
      translationConfig.key = _keyController.text.trim();
    }
    translationConfig.region = _regionController.text.trim();
    translationConfig.endpoint =
        _endpointController.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (!bundled || _xfAppIdController.text.trim().isNotEmpty) {
      speechConfig.appId = _xfAppIdController.text.trim();
    }
    if (!bundled || _xfApiKeyController.text.trim().isNotEmpty) {
      speechConfig.apiKey = _xfApiKeyController.text.trim();
    }
    if (!bundled || _xfApiSecretController.text.trim().isNotEmpty) {
      speechConfig.apiSecret = _xfApiSecretController.text.trim();
    }
    speechConfig.ugVcn = _xfUgVcnController.text.trim();
    speechConfig.zhVcn = _xfZhVcnController.text.trim();
    speechConfig.endpoint = _xfEndpointController.text.trim();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final String shownEndpoint = translationConfig.endpoint.trim().isEmpty
        ? _provider.defaultEndpoint
        : translationConfig.endpoint.trim();
    return AlertDialog(
      title: const Text('云端翻译设置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (kHasBundledCredentials)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    kBundledCredentialsNotice,
                    key: const ValueKey<String>('bundled-config-notice'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            // 配置摘要：截图即可确认包版本、服务商与终结点是否填错。
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '当前：${_provider.label} · $shownEndpoint'
                ' · 维语码 ${translationConfig.ugCode} · 语音诊断版',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Text('服务商'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<TranslationProvider>(
                    key: const ValueKey<String>('provider-field'),
                    value: _provider,
                    isExpanded: true,
                    items: TranslationProvider.values
                        .map<DropdownMenuItem<TranslationProvider>>(
                          (TranslationProvider item) =>
                              DropdownMenuItem<TranslationProvider>(
                            value: item,
                            child: Text(item.label),
                          ),
                        )
                        .toList(),
                    onChanged: (TranslationProvider? value) {
                      if (value != null) {
                        setState(() {
                          _provider = value;
                        });
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('niutrans-appid-field'),
              controller: _appIdController,
              decoration: const InputDecoration(
                labelText: '小牛 APPID',
                hintText: '控制台 → API应用',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('translator-key-field'),
              controller: _keyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API-KEY（Azure 填 Key 1）',
                hintText: '留空则只用本地演示词库',
                border: OutlineInputBorder(),
              ),
            ),
            if (_provider == TranslationProvider.azure) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('translator-region-field'),
                controller: _regionController,
                decoration: const InputDecoration(
                  labelText: 'Azure 区域（全球区留空）',
                  hintText: '例如 eastasia',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('translator-endpoint-field'),
              controller: _endpointController,
              decoration: const InputDecoration(
                labelText: '翻译终结点（留空用默认）',
                hintText: '自建 NAS 代理时填 http://...',
                border: OutlineInputBorder(),
              ),
            ),
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '语音（讯飞 WebAPI）· 手机号注册 + 实名，不用绑卡',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey<String>('xfyun-appid-field'),
              controller: _xfAppIdController,
              decoration: const InputDecoration(
                labelText: '讯飞 APPID',
                hintText: '控制台 → 应用',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('xfyun-apikey-field'),
              controller: _xfApiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '讯飞 APIKey',
                hintText: '多语种识别 / 语音合成服务页',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('xfyun-apisecret-field'),
              controller: _xfApiSecretController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '讯飞 APISecret',
                hintText: '只用于本地签名，不上传',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('xfyun-ugvcn-field'),
              controller: _xfUgVcnController,
              decoration: const InputDecoration(
                labelText: '维语发音人 vcn',
                hintText: '控制台开通维吾尔语发音人后可见',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('xfyun-zhvcn-field'),
              controller: _xfZhVcnController,
              decoration: const InputDecoration(
                labelText: '中文发音人 vcn',
                hintText: '默认 x4_xiaoyan',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('xfyun-endpoint-field'),
              controller: _xfEndpointController,
              decoration: const InputDecoration(
                labelText: '语音代理 wss 地址（可留空）',
                hintText: '自建 NAS 代理时填 wss://...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
