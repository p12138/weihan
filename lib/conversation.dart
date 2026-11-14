// 融合 App 的领域模型与端口定义。
// 不依赖 Flutter、网络或任何密钥；接入真实服务时只需新增端口实现。

import 'dart:async';
import 'dart:typed_data';

/// 消息语言。
enum Language {
  chinese('中文', 'zh'),
  uyghur('ئۇيغۇرچە', 'ug');

  const Language(this.label, this.code);

  /// 界面显示名。
  final String label;

  /// 语言代码，供未来的云端 API 使用。
  final String code;

  /// 维吾尔文使用阿拉伯字母，从右向左排版。
  bool get isRtl => this == Language.uyghur;
}

/// 翻译方向。
enum TranslationDirection {
  zhToUg(Language.chinese, Language.uyghur),
  ugToZh(Language.uyghur, Language.chinese);

  const TranslationDirection(this.source, this.target);

  /// 源语言。
  final Language source;

  /// 目标语言。
  final Language target;

  /// 切换方向。
  TranslationDirection get flipped => this == TranslationDirection.zhToUg
      ? TranslationDirection.ugToZh
      : TranslationDirection.zhToUg;
}

/// 一条对话消息。
class Message {
  const Message({
    required this.id,
    required this.text,
    required this.language,
    required this.isMine,
    this.isFinal = true,
  });

  final int id;
  final String text;
  final Language language;

  /// 是否为用户自己发出，决定气泡靠左还是靠右。
  final bool isMine;

  /// 是否已定稿。`false` 表示同声传译的临时草稿：界面用更淡的样式，
  /// 且不提供朗读按钮；定稿时用同一个 id 原位替换。
  final bool isFinal;

  /// 复制并替换可变字段，id / 语言 / 归属保持不变。
  Message copyWith({String? text, bool? isFinal}) => Message(
        id: id,
        text: text ?? this.text,
        language: language,
        isMine: isMine,
        isFinal: isFinal ?? this.isFinal,
      );
}

/// 翻译结果。
class Translation {
  const Translation({
    required this.text,
    required this.provider,
    required this.found,
    this.isDemo = true,
  });

  final String text;

  /// 实际命中的服务名，便于界面显示与排障。
  final String provider;

  /// 是否找到译文；false 表示所有服务都未收录或不可用。
  final bool found;

  /// 是否为离线演示结果，而非真实机器翻译。
  final bool isDemo;

  /// 所有服务都未命中时的统一返回值。
  static const Translation missing = Translation(
    text: '',
    provider: '无可用翻译服务',
    found: false,
  );
}

/// 翻译端口。云端实现（Azure / NiuTrans / Hunyuan）实现此接口即可接入。
abstract class Translator {
  const Translator();

  Future<Translation> translate(String text, Language from, Language to);
}

/// 离线演示词库：只覆盖常见寒暄句，明确不假装能翻译任意句子。
class DemoTranslator extends Translator {
  const DemoTranslator();

  static const Map<String, String> _phrases = <String, String>{
    '你好': 'ئەسسالامۇ ئەلەيكۇم',
    '谢谢': 'رەھمەت',
    '再见': 'خەير-خوش',
    '请': 'مەرھەمەت',
    '对不起': 'كەچۈرۈڭ',
    '是': 'ھەئە',
    '不': 'ياق',
    '我很好': 'مەن ياخشى',
    '你好吗': 'قانداق ئەھۋالىڭىز',
    '多少钱': 'قانچە پۇل',
    '我听不懂': 'چۈشەنمىدىم',
    '请再说一遍': 'قايتا بىر دەڭ',
  };

  static String? _lookup(String key, Language from) {
    if (from == Language.chinese) {
      return _phrases[key];
    }
    for (final MapEntry<String, String> entry in _phrases.entries) {
      if (entry.value == key) {
        return entry.key;
      }
    }
    return null;
  }

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    final String key = text.trim();
    final String? hit = _lookup(key, from);
    if (hit == null) {
      return const Translation(
        text: '',
        provider: '演示词库',
        found: false,
      );
    }
    return Translation(text: hit, provider: '演示词库', found: true);
  }
}

/// 降级链：按顺序尝试，命中即返回；单个服务异常时继续下一个。
class FallbackTranslator extends Translator {
  const FallbackTranslator(this.chain);

  final List<Translator> chain;

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    for (final Translator item in chain) {
      try {
        final Translation result = await item.translate(text, from, to);
        if (result.found) {
          return result;
        }
      } catch (_) {
        // 单个 provider 异常时降级到下一个，不让整条链断掉。
        continue;
      }
    }
    return Translation.missing;
  }
}

/// 会话状态：纯数据，便于单元测试。
class ConversationState {
  const ConversationState({
    this.messages = const <Message>[],
    this.direction = TranslationDirection.zhToUg,
  });

  final List<Message> messages;
  final TranslationDirection direction;

  /// 追加一条消息，返回新状态。
  ConversationState add(Message message) => ConversationState(
        messages: <Message>[...messages, message],
        direction: direction,
      );

  /// 按 id 原位替换；同 id 不存在时退化成追加。
  ///
  /// 同声传译的草稿气泡要在原位置持续变长、定稿时被整句译文覆盖，
  /// 所以不能像 [add] 那样每次都往列表尾部塞新消息。
  ConversationState upsert(Message message) {
    final int index =
        messages.indexWhere((Message item) => item.id == message.id);
    if (index < 0) {
      return add(message);
    }
    if (messages[index].text == message.text &&
        messages[index].isFinal == message.isFinal) {
      return this;
    }
    final List<Message> next = List<Message>.of(messages);
    next[index] = message;
    return ConversationState(messages: next, direction: direction);
  }

  /// 把消息插到 [anchorId] 之后；锚点不存在时退化成追加。
  ///
  /// 同传译文的返回时间可能晚于下一句的原文草稿；直接追加会把译文排到
  /// 下一句后面，所以译文必须紧跟在它对应的原文气泡下面。
  ConversationState insertAfter(int anchorId, Message message) {
    final int index =
        messages.indexWhere((Message item) => item.id == anchorId);
    if (index < 0) {
      return add(message);
    }
    final List<Message> next = List<Message>.of(messages);
    next.insert(index + 1, message);
    return ConversationState(messages: next, direction: direction);
  }

  /// 切换翻译方向，保留消息。
  ConversationState flip() => ConversationState(
        messages: messages,
        direction: direction.flipped,
      );
}

/// 语音端口：把 PCM 16k/16bit/单声道录音识别成文字，把文字合成成音频字节。
///
/// 默认实现明确不可用（按钮禁用），不假装录音或合成；真实实现见
/// `xfyun_speech.dart` 的 `XfyunSpeechPort`，可替换成 NAS 本地模型。
/// 保持可实例化，是为了让「未配置凭证时按钮禁用」这一行为有最简默认值。
class SpeechPort {
  const SpeechPort();

  bool get isAvailable => false;

  Future<String> listen(Uint8List audio, Language language) async {
    throw UnimplementedError('语音识别尚未接入');
  }

  Future<Uint8List> speak(String text, Language language) async {
    throw UnimplementedError('语音合成尚未接入');
  }
}
