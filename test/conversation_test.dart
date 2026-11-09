import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/conversation.dart';

class _StubTranslator extends Translator {
  const _StubTranslator(this.result);

  final Translation result;

  @override
  Future<Translation> translate(String text, Language from, Language to) async =>
      result;
}

class _ThrowingTranslator extends Translator {
  const _ThrowingTranslator();

  @override
  Future<Translation> translate(
    String text,
    Language from,
    Language to,
  ) async {
    throw StateError('provider unavailable');
  }
}

void main() {
  test('维文是 RTL，中文不是', () {
    expect(Language.uyghur.isRtl, isTrue);
    expect(Language.chinese.isRtl, isFalse);
  });

  test('方向的源语言、目标语言与翻转', () {
    const TranslationDirection direction = TranslationDirection.zhToUg;
    expect(direction.source, Language.chinese);
    expect(direction.target, Language.uyghur);
    expect(direction.flipped.source, Language.uyghur);
    expect(direction.flipped.flipped, direction);
  });

  test('会话状态追加消息后保持方向，且原状态不变', () {
    const ConversationState initial = ConversationState();
    final ConversationState next = initial.add(
      const Message(
        id: 0,
        text: '你好',
        language: Language.chinese,
        isMine: true,
      ),
    );
    expect(next.messages.length, 1);
    expect(initial.messages, isEmpty);
    expect(next.direction, initial.direction);
    expect(next.flip().direction, TranslationDirection.ugToZh);
    expect(next.flip().messages.length, 1);
  });

  test('演示词库中译维命中，并标记为演示结果', () async {
    const DemoTranslator translator = DemoTranslator();
    final Translation result = await translator.translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(result.isDemo, isTrue);
    expect(result.text, isNotEmpty);
    expect(result.provider, '演示词库');
  });

  test('演示词库维译中可反查回原句', () async {
    const DemoTranslator translator = DemoTranslator();
    final Translation forward = await translator.translate(
      '谢谢',
      Language.chinese,
      Language.uyghur,
    );
    final Translation back = await translator.translate(
      forward.text,
      Language.uyghur,
      Language.chinese,
    );
    expect(back.found, isTrue);
    expect(back.text, '谢谢');
  });

  test('未收录句子明确返回 found=false，不伪造译文', () async {
    const DemoTranslator translator = DemoTranslator();
    final Translation result = await translator.translate(
      '这是一句很长的自由文本',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isFalse);
    expect(result.text, isEmpty);
  });

  test('降级链跳过异常与未命中，取第一个命中', () async {
    const Translator chain = FallbackTranslator(<Translator>[
      _ThrowingTranslator(),
      DemoTranslator(),
    ]);
    final Translation result = await chain.translate(
      '你好',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isTrue);
    expect(result.provider, '演示词库');
  });

  test('降级链全部失败时返回统一的 missing 结果', () async {
    const Translator chain = FallbackTranslator(<Translator>[
      _StubTranslator(
        Translation(text: '', provider: 'stub', found: false),
      ),
      _ThrowingTranslator(),
    ]);
    final Translation result = await chain.translate(
      '随便',
      Language.chinese,
      Language.uyghur,
    );
    expect(result.found, isFalse);
    expect(result.provider, '无可用翻译服务');
  });

  test('语音端口第一阶段明确不可用', () {
    const SpeechPort speech = SpeechPort();
    expect(speech.isAvailable, isFalse);
  });
}
