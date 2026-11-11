import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand_mark.dart';
import 'bundled_config.dart';
import 'conversation.dart';
import 'default_speech.dart';
import 'default_translator.dart';
import 'device_audio.dart';
import 'glass.dart';
import 'palette_controller.dart';
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

  /// 手指是否还按在语音按钮上。开始录音是异步的，这期间用户可能已经松手，
  /// 用它决定「松手时是要真的结束，还是把这段空录音丢掉」。
  bool _holding = false;

  /// 正在申请权限 / 启动录音，避免连点重复起流。
  bool _starting = false;

  /// 录音时的实时音量（0..1），驱动浮层里的音量条。
  double _level = 0;
  StreamSubscription<double>? _levelSubscription;

  /// 录音计时。只在有音量回调时刷新界面，不额外起定时器 ——
  /// 定时器在 widget 测试里会一直挂着，pumpAndSettle 永远等不到收敛。
  final Stopwatch _recordWatch = Stopwatch();

  int _nextId = 0;
  AudioPort? _audioPort;
  late final SpeechPipeline _pipeline = SpeechPipeline(
    speech: widget.speech,
    translator: widget.translator,
  );

  @override
  void dispose() {
    _levelSubscription?.cancel();
    _levelSubscription = null;
    _audioPort?.dispose();
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

  /// 按住按钮：申请权限并开始录音。
  ///
  /// 录音启动是异步的，用户可能在这几百毫秒里就松手了。此时不能直接进入
  /// 「正在录音」，而是记下 [_holding]，启动完成后发现手指已抬走，就把这段
  /// 空录音丢掉 —— 否则会向云端提交一段 0 字节音频，再收到一个莫名其妙的报错。
  Future<void> _beginVoice() async {
    if (_starting || _recording || _busy) {
      return;
    }
    _holding = true;
    if (!widget.speech.isAvailable) {
      _holding = false;
      setState(() => _notice = '语音未接入 · 到设置页填讯飞 APPID / APIKey / APISecret');
      return;
    }
    _starting = true;
    try {
      final bool granted = await _audio().hasPermission();
      if (!mounted) {
        return;
      }
      if (!granted) {
        // 失败分支必须复位 _holding：否则下一次按住会带着「手指还按着」的
        // 残留状态，启动完录音后被误判成该丢弃。
        _holding = false;
        setState(() => _notice =
            '需要麦克风权限 · 在系统弹窗点「允许」，或到系统设置里开启后重试');
        return;
      }
      await _audio().startRecord();
      if (!mounted) {
        return;
      }
      if (!_holding) {
        // 松手比启动还快：这段录音作废
        await _stopSilently();
        return;
      }
      setState(() {
        _recording = true;
        _notice = '正在说话 · 松手结束';
      });
      _startLevels();
    } on Object catch (error) {
      _holding = false;
      if (!mounted) {
        return;
      }
      setState(() => _notice = '无法开始录音：${_brief(error.toString())}');
    } finally {
      _starting = false;
    }
  }

  /// 松手：结束录音并跑「识别 → 翻译 → 朗读」三环。
  Future<void> _endVoice() async {
    _holding = false;
    if (!_recording) {
      // 还在启动阶段，交给 _beginVoice 里的 _holding 判断
      return;
    }
    await _finishVoice();
  }

  /// 丢弃一段录音：结束不抛错，失败也只是日志。
  Future<void> _stopSilently() async {
    _stopLevels();
    try {
      await _audio().stopRecord();
    } on Object catch (error) {
      debugPrint('丢弃录音失败：$error');
    }
  }

  /// 订阅实时音量。没有这条流（假实现 / 平台不支持）时什么也不做，
  /// 浮层退化成不动的音量条，录音本身不受影响。
  void _startLevels() {
    _stopLevels();
    _recordWatch
      ..reset()
      ..start();
    _levelSubscription = _audio().levels.listen(
      (double level) {
        if (!mounted) {
          return;
        }
        setState(() => _level = level);
      },
      onError: (Object error) {
        debugPrint('音量流错误：$error');
      },
    );
  }

  void _stopLevels() {
    _levelSubscription?.cancel();
    _levelSubscription = null;
    _recordWatch
      ..stop()
      ..reset();
    _level = 0;
  }

  Future<void> _finishVoice() async {
    _stopLevels();
    setState(() {
      _recording = false;
      _busy = true;
      _notice = '正在识别与翻译…';
    });
    final TranslationDirection direction = _state.direction;
    String recordingInfo = '';
    try {
      final Uint8List pcm = await _audio().stopRecord();
      recordingInfo = _audio().recordingDiagnostics;
      if (pcm.isEmpty) {
        if (!mounted) {
          return;
        }
        setState(() {
          _busy = false;
          _notice = recordingInfo.isEmpty
              ? '没录到声音 · 请按住按钮说完再松手'
              : '没录到声音 · $recordingInfo · 请按住按钮说完再松手';
        });
        return;
      }
      final SpeechTurn turn = await _pipeline.run(pcm, direction);
      if (!mounted) {
        return;
      }
      final String? speakError = turn.speakError;
      setState(() {
        _busy = false;
        _state = _state.add(_newMessage(turn.heard, direction.source, true));
        if (turn.translation.found) {
          _state = _state.add(
            _newMessage(turn.translation.text, direction.target, false),
          );
          _notice = '识别到「${turn.heard}」· 由 ${turn.translation.provider} 翻译';
          if (speakError != null) {
            // 文字已经可用，只是没合成出音频：把原因摊开说，别让用户
            // 只看到「没有声音」而在设置页里瞎试。
            _notice = '$_notice · 朗读失败：${_brief(speakError)}';
          }
        } else {
          _notice = '识别到「${turn.heard}」· 但未返回译文';
        }
      });
      if (turn.hasAudio) {
        try {
          await _audio().play(turn.audio);
        } on Object catch (error) {
          if (!mounted) {
            return;
          }
          setState(() {
            _notice = '译文已出 · 播放失败：${_brief(error.toString())}';
          });
        }
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      final String diagnostic = speechConfig.lastDiagnostic.trim();
      // 把录音统计贴进失败提示：一眼分清「压根没录到」「录到了但云端没认出」
      // 和「音频发出去了但服务报错」，不用再靠猜。
      final String extra = recordingInfo.isEmpty ? '' : ' · $recordingInfo';
      setState(() {
        _busy = false;
        _notice =
            '语音失败 · ${diagnostic.isEmpty ? _brief(error.toString()) : _brief(diagnostic)}$extra';
      });
    }
  }

  Future<void> _speak(String text, Language language) async {
    try {
      final Uint8List audio = await widget.speech.speak(text, language);
      if (audio.isEmpty) {
        if (!mounted) {
          return;
        }
        setState(() {
          _notice = '没有拿到朗读音频 · 检查该语言发音人是否已在讯飞控制台开通';
        });
        return;
      }
      await _audio().play(audio);
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

  /// 直接点语言胶囊：把它设为「我说的话」。
  /// 已经是当前源语言就不动，避免点一下什么都没变化却闪一下动画。
  void _selectSource(Language language) {
    if (_state.direction.source == language) {
      return;
    }
    _flipDirection();
  }

  /// 顶栏的调色板按钮：按顺序切到下一套配色。
  /// 只改全局色板并通知，MaterialApp 会整棵树重建。
  void _cyclePalette() {
    const List<BrandPalette> all = BrandPalette.all;
    final int index =
        all.indexWhere((BrandPalette item) => item.id == AppColors.palette.id);
    final BrandPalette next = all[(index + 1) % all.length];
    PaletteController.instance.select(next);
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
                onSettings: _openSettings,
                onTheme: _cyclePalette,
              ),
              _DirectionCard(
                direction: direction,
                speechAvailable: speechReady,
                cloudEnabled: translationConfig.hasCloudConfig,
                onFlip: _flipDirection,
                onSelect: _selectSource,
              ),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
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
                    // 录音浮层：IgnorePointer 保证抬手事件仍然回到语音按钮，
                    // 不会因为浮层盖上来而丢一次松手。
                    if (_recording)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                              child: _RecordingPanel(
                                level: _level,
                                elapsed: _recordWatch.elapsed,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_notice.isNotEmpty) _NoticeBar(text: _notice),
              _Composer(
                controller: _controller,
                direction: direction,
                speechReady: speechReady,
                recording: _recording,
                busy: _busy,
                onSend: _busy || _recording ? null : _submit,
                onVoiceStart: _beginVoice,
                onVoiceEnd: _endVoice,
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

/// 顶栏：品牌标识 + 标语 + 操作。
///
/// 没用 AppBar：需要渐变底 + 徽标，AppBar 的 flexibleSpace 会带来
/// 额外的 elevation / 滚动变色逻辑，自绘容器更可控。
class _Header extends StatelessWidget {
  const _Header({required this.onSettings, required this.onTheme});

  final VoidCallback onSettings;
  final VoidCallback onTheme;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.of(context).padding.top;
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.headerGradient,
        boxShadow: const <BoxShadow>[
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
            tooltip: '切换配色主题',
            onPressed: onTheme,
            color: Colors.white,
            icon: const Icon(Icons.palette_outlined),
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

/// 方向切换卡：中文 / 维语两枚语言胶囊 + 中间交换键，下面一行是通道状态。
///
/// 语言与颜色是绑定关系：中文侧恒为主色，维文侧恒为强调色。换主题时两个颜色
/// 一起换，但「哪种语言是哪个颜色」不会变 —— 不看字也能认出当前是谁在说。
///
/// 状态行文案被既有测试依赖（`中文 → ئۇيغۇرچە`、`演示词库`、`语音待接入`），
/// 只能改样式不能改字符串结构。
class _DirectionCard extends StatelessWidget {
  const _DirectionCard({
    required this.direction,
    required this.speechAvailable,
    required this.cloudEnabled,
    required this.onFlip,
    required this.onSelect,
  });

  final TranslationDirection direction;
  final bool speechAvailable;
  final bool cloudEnabled;
  final VoidCallback onFlip;
  final ValueChanged<Language> onSelect;

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
        corner: 22,
        fillOpacity: 0.78,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _LanguagePill(
                    language: Language.chinese,
                    active: direction.source == Language.chinese,
                    onTap: () => onSelect(Language.chinese),
                  ),
                ),
                _SwapButton(onTap: onFlip),
                Expanded(
                  child: _LanguagePill(
                    language: Language.uyghur,
                    active: direction.source == Language.uyghur,
                    onTap: () => onSelect(Language.uyghur),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Icon(
                  ready ? Icons.check_circle_outline : Icons.info_outline,
                  size: 13,
                  color: ready ? AppColors.primary : AppColors.accentInk,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: ready ? AppColors.primaryDeep : AppColors.accentInk,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 语言胶囊：激活态用该语言的主题色渐变，未激活态用同色系的浅底细边。
/// 左侧「汉 / 维」小方块是给一眼扫过用的，右边的文字才是完整语言名。
class _LanguagePill extends StatelessWidget {
  const _LanguagePill({
    required this.language,
    required this.active,
    required this.onTap,
  });

  final Language language;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool uyghur = language.isRtl;
    final Color color = AppColors.language(uyghur);
    final Color soft = AppColors.languageSoft(uyghur);
    final String badge = uyghur ? '维' : '汉';

    return Semantics(
      button: true,
      selected: active,
      label: '${language.label}${active ? '（我在说）' : ''}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            gradient: active ? AppColors.gradientOf(uyghur) : null,
            color: active ? null : soft.withOpacity(0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? Colors.transparent : color.withOpacity(0.30),
              width: 1,
            ),
            boxShadow: active
                ? <BoxShadow>[
                    BoxShadow(
                      color: color.withOpacity(0.30),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? Colors.white.withOpacity(0.24) : color,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Directionality(
                  textDirection: uyghur ? TextDirection.rtl : TextDirection.ltr,
                  child: Text(
                    language.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: uyghur ? 13 : 13.5,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: active ? Colors.white : color,
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

/// 中间的交换键。图标用 swap_horiz，左右对称所以不做翻转动画，
/// 变化体现在两侧胶囊的渐变切换上。
class _SwapButton extends StatelessWidget {
  const _SwapButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(color: AppColors.line),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppColors.primaryDeep.withOpacity(0.10),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: IconButton(
          tooltip: '切换翻译方向',
          onPressed: onTap,
          icon: const Icon(Icons.swap_horiz, size: 20),
          color: AppColors.primary,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
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
                    gradient: AppColors.gradient,
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
                  icon: Icons.touch_app_outlined,
                  title: '按住按钮说话',
                  detail: '松手就自动识别并翻译，说完立刻听到译文',
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
                style: TextStyle(
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
          Icon(
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
    required this.busy,
    required this.onSend,
    required this.onVoiceStart,
    required this.onVoiceEnd,
  });

  final TextEditingController controller;
  final TranslationDirection direction;
  final bool speechReady;
  final bool recording;
  final bool busy;
  final VoidCallback? onSend;
  final VoidCallback onVoiceStart;
  final VoidCallback onVoiceEnd;

  @override
  Widget build(BuildContext context) {
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
                          borderSide: BorderSide(color: AppColors.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(color: AppColors.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide(
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
              // 按住说话：整页唯一的语音入口，测试用 Key('voice-button') 定位。
              SizedBox(
                width: double.infinity,
                child: _VoiceButton(
                  ready: speechReady,
                  recording: recording,
                  busy: busy,
                  onStart: onVoiceStart,
                  onEnd: onVoiceEnd,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 按住说话按钮。
///
/// 用 [Listener] 而不是 GestureDetector：手势竞技场要等手指抬起才判胜负，
/// 而这里「按下」就必须立刻开始录音。Listener 拿到的是原始指针事件，
/// 按下、抬起、被系统打断（来电、下拉通知栏）都能第一时间响应。
///
/// 手指滑出按钮范围再松开也能收到 up —— 指针事件会继续投递给按下时的命中路径，
/// 不会出现「录着录着一松手停不下来」。
class _VoiceButton extends StatefulWidget {
  const _VoiceButton({
    required this.ready,
    required this.recording,
    required this.busy,
    required this.onStart,
    required this.onEnd,
  });

  final bool ready;
  final bool recording;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onEnd;

  @override
  State<_VoiceButton> createState() => _VoiceButtonState();
}

class _VoiceButtonState extends State<_VoiceButton> {
  /// 手指是否按在按钮上：只影响视觉反馈，录音状态由父层管。
  bool _down = false;

  bool get _enabled => widget.ready && !widget.busy;

  String get _label {
    if (!widget.ready) {
      return '按住说话 · 待接入';
    }
    if (widget.recording) {
      return '松手结束 · 正在录音';
    }
    if (widget.busy) {
      return '正在识别与翻译…';
    }
    return '按住说话 · 松手翻译';
  }

  IconData get _icon {
    if (!widget.ready) {
      return Icons.mic_off_outlined;
    }
    if (widget.recording) {
      return Icons.graphic_eq;
    }
    return widget.busy ? Icons.cloud_sync_outlined : Icons.mic;
  }

  void _press() {
    setState(() => _down = true);
    widget.onStart();
  }

  void _release() {
    if (_down) {
      setState(() => _down = false);
    }
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final bool active = widget.recording;
    final bool pressed = active || _down;

    // 录音中换成警示色渐变，和空闲时的品牌渐变拉开距离
    final LinearGradient? gradient = !_enabled
        ? null
        : pressed
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  AppColors.coral,
                  Color.lerp(AppColors.coral, Colors.black, 0.24) ??
                      AppColors.coral,
                ],
              )
            : AppColors.gradient;

    return Semantics(
      button: true,
      enabled: _enabled,
      label: _label,
      hint: '按住不动说话，松开手指结束',
      child: Listener(
        key: const ValueKey<String>('voice-button'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _press(),
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: AnimatedScale(
          scale: pressed ? 0.975 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              gradient: gradient,
              color: _enabled ? null : AppColors.line,
              borderRadius: BorderRadius.circular(29),
              boxShadow: _enabled
                  ? <BoxShadow>[
                      BoxShadow(
                        color: (active ? AppColors.coral : AppColors.primaryDeep)
                            .withOpacity(0.28),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _enabled
                        ? Colors.white.withOpacity(0.22)
                        : Colors.white.withOpacity(0.55),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _icon,
                    size: 18,
                    color: _enabled ? Colors.white : AppColors.inkMuted,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    _label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: _enabled ? Colors.white : AppColors.inkMuted,
                    ),
                  ),
                ),
                if (_enabled) ...<Widget>[
                  const SizedBox(width: 10),
                  _Waveform(active: active),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 录音时点亮的五根声波条。静态高度，不做循环动画 ——
/// 无限动画会让测试里的 pumpAndSettle 永远等不到收敛。
class _Waveform extends StatelessWidget {
  const _Waveform({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    const List<double> heights = <double>[8, 15, 22, 13, 9];
    return Row(
      children: heights
          .map(
            (double height) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 3,
                height: active ? height : height * 0.55,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(active ? 0.95 : 0.45),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

/// 录音时浮在会话区底部的「微信式」音量卡片。
///
/// 条高直接吃真实麦克风音量（[level] 0..1），不是随机数：一旦没有输入就
/// 贴地平躺，用户能一眼判断「到底有没有在收我的声音」。
///
/// 用 AnimatedContainer 做一次性补间，不挂 Timer、不用 repeat ——
/// 否则 widget 测试里的 pumpAndSettle 会永远等不到收敛。
class _RecordingPanel extends StatelessWidget {
  const _RecordingPanel({required this.level, required this.elapsed});

  /// 当前音量，0（安静）～ 1（满幅）。
  final double level;

  /// 已录时长。
  final Duration elapsed;

  String get _clock {
    final int total = elapsed.inSeconds;
    final String seconds = (total % 60).toString().padLeft(2, '0');
    final String minutes = (total ~/ 60).toString();
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AppColors.primaryDeep.withOpacity(0.94),
            Color.lerp(AppColors.primaryDeep, Colors.black, 0.3) ??
                AppColors.primaryDeep,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.primaryDeep.withOpacity(0.32),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          AnimatedScale(
            scale: 1 + level * 0.1,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.22)),
              ),
              child: const Icon(Icons.mic, size: 22, color: Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _LiveBars(level: level),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Text(
                      '松手结束',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.92),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _clock,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.62),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 13 根随音量起伏的竖条：中间高、两边低，像一段被压扁的波形。
class _LiveBars extends StatelessWidget {
  const _LiveBars({required this.level});

  final double level;

  static const int _count = 13;

  /// 中间高两边低的包络，保证静止时也是一条有形状的波形而不是一排等号。
  double _envelope(int index) {
    final double distance =
        (index - (_count - 1) / 2).abs() / ((_count - 1) / 2);
    return (1 - distance) * 0.75 + 0.25;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List<Widget>.generate(_count, (int index) {
          final double envelope = _envelope(index);
          final double height = 4 + 26 * level * envelope;
          return Padding(
            padding: const EdgeInsets.only(right: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              width: 3,
              height: height.clamp(4.0, 30.0).toDouble(),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.35 + 0.55 * level),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
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
        gradient: enabled ? AppColors.gradient : null,
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
        gradient: mine ? AppColors.gradient : null,
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
    // 主题是全局色板，切完不会自动重建这个对话框，手动订阅一次。
    PaletteController.instance.addListener(_onPaletteChanged);
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

  void _onPaletteChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    PaletteController.instance.removeListener(_onPaletteChanged);
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
                   Icon(Icons.tune, size: 20, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
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
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: AppColors.primaryDeep,
                          ),
                        ),
                      ),
                    const _SectionTitle(
                      icon: Icons.palette_outlined,
                      label: '主题配色',
                      note: '立即生效，重启后保留',
                    ),
                    const SizedBox(height: 12),
                    const _ThemePicker(),
                    const SizedBox(height: 22),
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
                        ' · 主题 ${AppColors.palette.name} · 玻璃 ${Glass.spec.label}',
                        style: TextStyle(
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

/// 主题选择器：四套配色的色点 + 名字，点一下立刻换。
///
/// 色点用的是该主题自己的主色与强调色，所以「选哪套」不用读文字也能看出来。
class _ThemePicker extends StatelessWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context) {
    final String currentId = AppColors.palette.id;
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: BrandPalette.all
          .map(
            (BrandPalette palette) => _ThemeChip(
              palette: palette,
              selected: palette.id == currentId,
            ),
          )
          .toList(),
    );
  }
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip({required this.palette, required this.selected});

  final BrandPalette palette;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '主题 ${palette.name}（${palette.note}）',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => PaletteController.instance.select(palette),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(9, 8, 12, 8),
          decoration: BoxDecoration(
            color: selected ? palette.primarySoft : Colors.white,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? palette.primary : AppColors.line,
              width: selected ? 1.8 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 20,
                child: Stack(
                  children: <Widget>[
                    Positioned(left: 0, child: _dot(palette.primary)),
                    Positioned(right: 0, child: _dot(palette.accent)),
                  ],
                ),
              ),
              const SizedBox(width: 7),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    palette.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: selected ? palette.primaryDeep : AppColors.ink,
                    ),
                  ),
                  Text(
                    palette.note,
                    style: TextStyle(
                      fontSize: 9.5,
                      height: 1.3,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withOpacity(0.35),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      );
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
          style: TextStyle(
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
          style: TextStyle(
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
