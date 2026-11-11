import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand_mark.dart';
import 'bundled_config.dart';
import 'conversation.dart';
import 'default_speech.dart';
import 'default_translator.dart';
import 'device_audio.dart';
import 'glass.dart';
import 'speech_config.dart';
import 'speech_pipeline.dart';
import 'theme.dart';
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
        _notice =
            '语音失败 · ${diagnostic.isEmpty ? _brief(error.toString()) : _brief(diagnostic)}';
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
        _notice =
            '朗读失败 · ${diagnostic.isEmpty ? _brief(error.toString()) : _brief(diagnostic)}';
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        // 底色交给 AuroraBackground，玻璃面板才能"透"出颜色
        backgroundColor: Colors.transparent,
        body: AuroraBackground(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(
                onFlip: _flipDirection,
                onSettings: _openSettings,
              ),
              _StatusStrip(
                direction: direction,
                speechAvailable: speechReady,
                cloudEnabled: translationConfig.hasCloudConfig,
              ),
              Expanded(
                child: _state.messages.isEmpty
                    ? const _EmptyState()
                    : _buildConversation(
                        onSpeak: speechReady
                            ? (String text, Language language) {
                                _speak(text, language);
                              }
                            : null,
                      ),
              ),
              if (_notice.isNotEmpty) _NoticeBar(text: _notice),
              _Composer(
                controller: _controller,
                direction: direction,
                speechReady: speechReady,
                recording: _recording,
                onSend: _busy || _recording ? null : _submit,
                onVoice: speechReady
                    ? () {
                        _tapVoice();
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConversation({SpeakCallback? onSpeak}) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      itemCount: _state.messages.length,
      itemBuilder: (BuildContext context, int index) => MessageBubble(
        message: _state.messages[index],
        onSpeak: onSpeak,
      ),
    );
  }
}

typedef SpeakCallback = void Function(String text, Language language);

/// 顶栏：品牌标识 + 标语 + 两个操作。
///
/// 没用 AppBar：需要渐变底 + 徽标，AppBar 的 flexibleSpace 会带来
/// 额外的 elevation / 滚动变色逻辑，自绘容器更可控。
class _Header extends StatelessWidget {
  const _Header({
    required this.onFlip,
    required this.onSettings,
  });

  final VoidCallback onFlip;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return Container(
      decoration: const BoxDecoration(
        gradient: AppColors.headerGradient,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x1A0B3A36),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(16, topInset + 12, 6, 16),
      child: Row(
        children: <Widget>[
          const BrandBadge(size: 42),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '融合',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '让沟通不再有障碍',
                  style: TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 11.5,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '切换翻译方向',
            onPressed: onFlip,
            color: Colors.white,
            icon: const Icon(Icons.swap_horiz),
          ),
          IconButton(
            tooltip: '云端翻译与语音设置',
            onPressed: onSettings,
            color: Colors.white,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
    );
  }
}

/// 状态条：方向 / 翻译通道 / 语音通道，一条读懂当前配置。
///
/// 文案格式被既有测试依赖（`中文 → ئۇيغۇرچە`、`演示词库`、`语音待接入`），
/// 只能改样式不能改字符串结构。
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
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
    final bool ready = cloudEnabled && speechAvailable;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: GlassPanel(
        corner: 16,
        fillOpacity: 0.78,
        tint: ready ? AppColors.primarySoft : AppColors.sandSoft,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: <Widget>[
            Icon(
              ready ? Icons.check_circle_outline : Icons.info_outline,
              size: 16,
              color: ready ? AppColors.primary : const Color(0xFF9A7233),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: ready ? AppColors.primaryDeep : const Color(0xFF7A5A22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空状态：一句话说明这个 App 干什么，再给三个操作提示。
/// 这是用户打开应用后第一眼看到的内容，比一闪而过的启动动画更有价值。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight > 42
                  ? constraints.maxHeight - 42
                  : 0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Color(0xFF1B7168), AppColors.primaryDeep],
                    ),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x3317635C),
                        blurRadius: 22,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(14),
                  child: const BrandMark(size: 64),
                ),
                const SizedBox(height: 22),
                Text(
                  '对着手机说一句，对方立刻听得懂',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: 19,
                        height: 1.5,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  '中文与维吾尔语双向翻译，说完自动朗读',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                      ),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.sandSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    '让您和您的民族朋友沟通不再有障碍',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF7A5A22),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const _HintRow(
                  icon: Icons.mic_none,
                  title: '点一下麦克风说话',
                  detail: '说完再点一次，自动识别并翻译',
                ),
                const SizedBox(height: 14),
                const _HintRow(
                  icon: Icons.volume_up_outlined,
                  title: '译文会自动朗读',
                  detail: '想再听一遍，点气泡右侧的喇叭',
                ),
                const SizedBox(height: 14),
                const _HintRow(
                  icon: Icons.text_fields,
                  title: '也可以直接打字',
                  detail: '维文按从右到左排版，不会错行',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HintRow extends StatelessWidget {
  const _HintRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 2),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// 底部提示条：录音、识别、失败的反馈都走这里，一直可见不弹窗。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.campaign_outlined,
            size: 15,
            color: AppColors.inkMuted,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部输入区：文本框 + 发送 + 大号语音按钮。
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.direction,
    required this.speechReady,
    required this.recording,
    required this.onSend,
    required this.onVoice,
  });

  final TextEditingController controller;
  final TranslationDirection direction;
  final bool speechReady;
  final bool recording;
  final VoidCallback? onSend;
  final VoidCallback? onVoice;

  @override
  Widget build(BuildContext context) {
    final String voiceLabel = recording
        ? '正在录音 · 点击结束'
        : (speechReady ? '点击说话 · 再点结束' : '按住说话 · 待接入');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: GlassPanel(
        corner: 26,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 4,
                      textDirection: direction.source.isRtl
                          ? TextDirection.rtl
                          : TextDirection.ltr,
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontSize: 15.5, height: 1.4),
                      decoration: InputDecoration(
                        hintText: '输入${direction.source.label}…',
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.62),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(color: AppColors.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(color: AppColors.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(
                            color: AppColors.primary,
                            width: 1.6,
                          ),
                        ),
                      ),
                      onSubmitted: (String value) {
                        onSend?.call();
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SendButton(onSend: onSend),
                ],
              ),
              const SizedBox(height: 10),
              // 全页唯一的 TextButton：既有 UI 测试用它判定「语音入口是否可用」，
              // 换成别的按钮类型会让回归断言失效，改动这里要同步改测试。
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: onVoice,
                  icon: Icon(recording ? Icons.stop_circle : Icons.mic),
                  label: Text(voiceLabel),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 54),
                    backgroundColor:
                        recording ? AppColors.coral : AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.line,
                    disabledForegroundColor: AppColors.inkMuted,
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.onSend});

  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onSend != null;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: enabled
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFF1B7168), AppColors.primaryDeep],
              )
            : null,
        color: enabled ? null : AppColors.line,
        shape: BoxShape.circle,
        boxShadow: enabled
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x3317635C),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: IconButton(
        tooltip: '发送',
        onPressed: onSend,
        icon: const Icon(Icons.send, size: 20),
        color: Colors.white,
        disabledColor: AppColors.inkMuted,
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
    final bool mine = message.isMine;
    final double maxWidth = MediaQuery.of(context).size.width * 0.74;

    final Widget bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: mine
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFF1D7169), AppColors.primaryDeep],
              )
            : null,
        color: mine ? null : AppColors.card,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 6),
          bottomRight: Radius.circular(mine ? 6 : 18),
        ),
        border: mine ? null : Border.all(color: AppColors.line),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0F0B3A36),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: Text(
          message.text,
          textAlign: rtl ? TextAlign.right : TextAlign.left,
          style: rtl
              ? AppTheme.uyghurBody.copyWith(
                  color: mine ? Colors.white : AppColors.ink,
                )
              : TextStyle(
                  fontSize: 16,
                  height: 1.5,
                  color: mine ? Colors.white : AppColors.ink,
                ),
        ),
      ),
    );

    final SpeakCallback? speak = onSpeak;
    if (mine || speak == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: bubble,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          Flexible(child: bubble),
          const SizedBox(width: 6),
          _SpeakButton(
            onTap: () => speak(message.text, message.language),
          ),
        ],
      ),
    );
  }
}

class _SpeakButton extends StatelessWidget {
  const _SpeakButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primarySoft,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: '朗读这句译文',
        onPressed: onTap,
        icon: const Icon(Icons.volume_up, size: 19),
        color: AppColors.primary,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 38, height: 38),
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
    const bool bundled = kHasBundledCredentials;
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
    const bool bundled = kHasBundledCredentials;
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
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
      child: GlassPanel(
        corner: 26,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 620),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 8, 14),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.tune, size: 20, color: AppColors.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '云端翻译设置',
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
            ),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (kHasBundledCredentials)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: AppColors.primarySoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          kBundledCredentialsNotice,
                          key: const ValueKey<String>('bundled-config-notice'),
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: AppColors.primaryDeep,
                          ),
                        ),
                      ),
                    const _SectionTitle(
                      icon: Icons.translate,
                      label: '文字翻译',
                    ),
                    const SizedBox(height: 12),
                    _ProviderField(
                      value: _provider,
                      onChanged: (TranslationProvider? value) {
                        if (value != null) {
                          setState(() {
                            _provider = value;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('niutrans-appid-field'),
                      controller: _appIdController,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '小牛 APPID',
                        hintText: '控制台 → API应用',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('translator-key-field'),
                      controller: _keyController,
                      obscureText: true,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: 'API-KEY（Azure 填 Key 1）',
                        hintText: '留空则只用本地演示词库',
                      ),
                    ),
                    if (_provider == TranslationProvider.azure) ...<Widget>[
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey<String>('translator-region-field'),
                        controller: _regionController,
                        style: const TextStyle(fontSize: 14.5),
                        decoration: const InputDecoration(
                          labelText: 'Azure 区域（全球区留空）',
                          hintText: '例如 eastasia',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('translator-endpoint-field'),
                      controller: _endpointController,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '翻译终结点（留空用默认）',
                        hintText: '自建 NAS 代理时填 http://...',
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _SectionTitle(
                      icon: Icons.graphic_eq,
                      label: '语音（讯飞 WebAPI）',
                      note: '手机号注册 + 实名，不用绑卡',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('xfyun-appid-field'),
                      controller: _xfAppIdController,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '讯飞 APPID',
                        hintText: '控制台 → 应用',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('xfyun-apikey-field'),
                      controller: _xfApiKeyController,
                      obscureText: true,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '讯飞 APIKey',
                        hintText: '多语种识别 / 语音合成服务页',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('xfyun-apisecret-field'),
                      controller: _xfApiSecretController,
                      obscureText: true,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '讯飞 APISecret',
                        hintText: '只用于本地签名，不上传',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('xfyun-ugvcn-field'),
                      controller: _xfUgVcnController,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '维语发音人 vcn',
                        hintText: '控制台开通维吾尔语发音人后可见',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('xfyun-zhvcn-field'),
                      controller: _xfZhVcnController,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '中文发音人 vcn',
                        hintText: '默认 x4_xiaoyan',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('xfyun-endpoint-field'),
                      controller: _xfEndpointController,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: const InputDecoration(
                        labelText: '语音代理 wss 地址（可留空）',
                        hintText: '自建 NAS 代理时填 wss://...',
                      ),
                    ),
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.line),
                      ),
                      child: Text(
                        '当前：${_provider.label} · $shownEndpoint'
                        ' · 维语码 ${translationConfig.ugCode} · 语音诊断版'
                        ' · 玻璃 ${Glass.spec.label}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Row(
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.inkMuted,
                    ),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.label,
    this.note,
  });

  final IconData icon;
  final String label;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              note!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                  ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ProviderField extends StatelessWidget {
  const _ProviderField({required this.value, required this.onChanged});

  final TranslationProvider value;
  final ValueChanged<TranslationProvider?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<TranslationProvider>(
          key: const ValueKey<String>('provider-field'),
          value: value,
          isExpanded: true,
          borderRadius: BorderRadius.circular(14),
          style: const TextStyle(
            fontSize: 14.5,
            color: AppColors.ink,
            fontWeight: FontWeight.w500,
          ),
          items: TranslationProvider.values
              .map<DropdownMenuItem<TranslationProvider>>(
                (TranslationProvider item) =>
                    DropdownMenuItem<TranslationProvider>(
                  value: item,
                  child: Text(item.label),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
