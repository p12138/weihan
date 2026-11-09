import 'package:flutter/material.dart';

import 'conversation.dart';
import 'default_translator.dart';
import 'translation_config.dart';

/// 对话页：文字互译、方向切换、双语气泡（维文自动 RTL）。
class ConversationPage extends StatefulWidget {
  ConversationPage({
    super.key,
    Translator? translator,
    this.speech = const SpeechPort(),
  }) : translator = translator ?? buildDefaultTranslator();

  final Translator translator;
  final SpeechPort speech;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final TextEditingController _controller = TextEditingController();
  ConversationState _state = const ConversationState();
  String _notice = '';
  bool _busy = false;
  int _nextId = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
        final String short = diagnostic.length > 200
            ? '${diagnostic.substring(0, 200)}…'
            : diagnostic;
        _notice = translationConfig.hasCloudConfig
            ? (short.isEmpty
                ? '云端翻译未返回译文 · 请检查 APPID / API-KEY / 网络'
                : '云端失败 · $short')
            : '演示词库未收录这句 · 配置小牛翻译后可翻译任意句子';
      }
    });
  }

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('维汉互译'),
        actions: <Widget>[
          IconButton(
            tooltip: '云端翻译设置',
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
            speechAvailable: widget.speech.isAvailable,
            cloudEnabled: translationConfig.hasCloudConfig,
          ),
          Expanded(child: _buildList()),
          if (_notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _notice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          _buildComposer(direction),
        ],
      ),
    );
  }

  Widget _buildList() {
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
      itemBuilder: (BuildContext context, int index) =>
          MessageBubble(message: _state.messages[index]),
    );
  }

  Widget _buildComposer(TranslationDirection direction) {
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
                  onPressed: _busy
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
              message: '语音识别与合成尚未接入',
              child: TextButton.icon(
                onPressed: null,
                icon: const Icon(Icons.mic_off),
                label: const Text('按住说话 · 待接入'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

/// 单条消息气泡，按语言自动选择排版方向。
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final bool rtl = message.language.isRtl;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Align(
      alignment:
          message.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
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
      ),
    );
  }
}

/// 云端翻译设置。密钥只保存在进程内存里，不落盘、不入库、不随包分发。
/// 切换服务商后翻译链会在下一次发送时立即按新配置重建。
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
  late TranslationProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = translationConfig.provider;
    _appIdController = TextEditingController(text: translationConfig.appId);
    _keyController = TextEditingController(text: translationConfig.key);
    _regionController = TextEditingController(text: translationConfig.region);
    _endpointController =
        TextEditingController(text: translationConfig.endpoint);
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _keyController.dispose();
    _regionController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  void _save() {
    translationConfig.provider = _provider;
    translationConfig.appId = _appIdController.text.trim();
    translationConfig.key = _keyController.text.trim();
    translationConfig.region = _regionController.text.trim();
    translationConfig.endpoint =
        _endpointController.text.trim().replaceAll(RegExp(r'/+$'), '');
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
            // 配置摘要：截图即可确认包版本、服务商与终结点是否填错。
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '当前：${_provider.label} · $shownEndpoint'
                ' · 维语码 ${translationConfig.ugCode} · 诊断版',
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
                labelText: '终结点（留空用默认）',
                hintText: '自建 NAS 代理时填 http://...',
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
