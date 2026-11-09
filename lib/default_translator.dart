// 默认翻译链。按当前配置动态构建，设置页切换后端后立即生效，无需重建页面。

import 'azure_translator.dart';
import 'conversation.dart';
import 'niutrans_translator.dart';
import 'translation_config.dart';

/// 页面默认使用的翻译链代理。
Translator buildDefaultTranslator() =>
    ConfigurableTranslator(translationConfig);

/// 运行时可切换的翻译链代理：每次调用都重新读取配置。
class ConfigurableTranslator extends Translator {
  const ConfigurableTranslator(this.config);

  final TranslationConfig config;

  @override
  Future<Translation> translate(String text, Language from, Language to) =>
      _chain().translate(text, from, to);

  Translator _chain() {
    switch (config.provider) {
      case TranslationProvider.demo:
        return const FallbackTranslator(<Translator>[DemoTranslator()]);
      case TranslationProvider.azure:
        return FallbackTranslator(<Translator>[
          AzureTranslator(config: config),
          const DemoTranslator(),
        ]);
      case TranslationProvider.niuTrans:
        return FallbackTranslator(<Translator>[
          NiuTransTranslator(config: config),
          const DemoTranslator(),
        ]);
    }
  }
}
