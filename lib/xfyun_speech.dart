// 讯飞 WebAPI 语音识别（ASR）与语音合成（TTS）的纯 Dart 实现。
//
// 官方文档：
//   - 大模型多语种语音识别 https://www.xfyun.cn/doc/spark/spark_mul_cn_iat.html
//   - 在线语音合成（流式版） https://www.xfyun.cn/doc/tts/online_tts/API.html
//
// 两端都是 wss + HMAC-SHA256 签名，签名只在本地计算，APISecret 不随包分发。
// 维语识别用官方语种表里的 `ln=ug`，中文用 `ln=zh`；维语朗读需要控制台
// 开通的维吾尔语发音人 vcn（不同账号可能不同，故由设置页填写）。
//
// 传输层可注入：单元测试用假 socket 回放官方响应帧，不发任何网络请求；
// 真实连通性由 CI 的 live check 用 Secret 验证。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'conversation.dart';
import 'speech_config.dart';

/// 语音链路异常。
class SpeechException implements Exception {
  const SpeechException(this.message);

  final String message;

  @override
  String toString() => 'SpeechException: $message';
}

/// WebSocket 传输抽象，便于单测替换。
abstract class XfyunSocket {
  void send(String text);

  Stream<String> get messages;

  Future<void> close();
}

/// 建立连接的函数类型。
typedef XfyunSocketOpener = Future<XfyunSocket> Function(Uri uri);

/// 生成 RFC1123 GMT 时间的函数类型（注入后签名可单测）。
typedef XfyunDateBuilder = String Function();

/// dart:io 的 WebSocket 适配器。
class DartIoXfyunSocket implements XfyunSocket {
  DartIoXfyunSocket(this._socket);

  final WebSocket _socket;

  @override
  void send(String text) {
    _socket.add(text);
  }

  @override
  Stream<String> get messages =>
      _socket.map((dynamic event) => event.toString());

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

Future<XfyunSocket> openXfyunSocket(Uri uri) async {
  final WebSocket socket = await WebSocket.connect(uri.toString());
  return DartIoXfyunSocket(socket);
}

/// RFC1123 GMT 时间，服务端允许 300 秒时钟偏移。
String buildXfyunDate(DateTime utc) {
  const List<String> weekdays = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final DateTime d = utc.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${weekdays[d.weekday - 1]}, ${two(d.day)} ${months[d.month - 1]} '
      '${d.year} ${two(d.hour)}:${two(d.minute)}:${two(d.second)} GMT';
}

/// 签名摘要：base64(hmac-sha256("host: h\ndate: d\nGET path HTTP/1.1"))。
/// 官方文档「大模型多语种语音识别」给出的示例值已用它复算对齐。
String buildXfyunSignature({
  required String host,
  required String path,
  required String date,
  required String apiSecret,
}) {
  final String origin = 'host: $host\ndate: $date\nGET $path HTTP/1.1';
  final Hmac hmac = Hmac(sha256, utf8.encode(apiSecret));
  return base64.encode(hmac.convert(utf8.encode(origin)).bytes);
}

/// authorization 参数：对签名串再做一次 base64。
String buildXfyunAuthorization({
  required String host,
  required String path,
  required String date,
  required String apiKey,
  required String apiSecret,
}) {
  final String signature = buildXfyunSignature(
    host: host,
    path: path,
    date: date,
    apiSecret: apiSecret,
  );
  final String origin = 'api_key="$apiKey",algorithm="hmac-sha256",'
      'headers="host date request-line",signature="$signature"';
  return base64.encode(utf8.encode(origin));
}

/// 带鉴权参数的 wss 地址。Uri 会自动 percent-encode base64 里的 + / =。
Uri buildXfyunUri({
  required String host,
  required String path,
  required String date,
  required String apiKey,
  required String apiSecret,
}) {
  return Uri(
    scheme: 'wss',
    host: host,
    path: path,
    queryParameters: <String, String>{
      'host': host,
      'date': date,
      'authorization': buildXfyunAuthorization(
        host: host,
        path: path,
        date: date,
        apiKey: apiKey,
        apiSecret: apiSecret,
      ),
    },
  );
}

/// 识别首帧：带 parameter 指定语种，后续帧只带音频。
String buildAsrFirstFrame({
  required String appId,
  required String ln,
  required String audio,
  int sampleRate = 16000,
  int eos = 6000,
}) {
  return jsonEncode(<String, Object>{
    'header': <String, Object>{'app_id': appId, 'status': 0},
    'parameter': <String, Object>{
      'iat': <String, Object>{
        'domain': 'slm',
        'language': 'mul_cn',
        'accent': 'mandarin',
        'ln': ln,
        'eos': eos,
        'result': <String, Object>{
          'encoding': 'utf8',
          'compress': 'raw',
          'format': 'json',
        },
      },
    },
    'payload': <String, Object>{
      'audio': <String, Object>{
        'encoding': 'raw',
        'sample_rate': sampleRate,
        'channels': 1,
        'bit_depth': 16,
        'seq': 1,
        'status': 0,
        'audio': audio,
      },
    },
  });
}

/// 中间帧 / 结束帧。status：1 继续，2 结束。
String buildAsrAudioFrame({
  required String appId,
  required int status,
  required String audio,
  int sampleRate = 16000,
  int seq = 1,
}) {
  return jsonEncode(<String, Object>{
    'header': <String, Object>{'app_id': appId, 'status': status},
    'payload': <String, Object>{
      'audio': <String, Object>{
        'encoding': 'raw',
        'sample_rate': sampleRate,
        'status': status,
        'seq': seq,
        'audio': audio,
      },
    },
  });
}

/// 把 16k/16bit/单声道 PCM 切成 1280 字节（40ms）的 base64 帧。
List<String> buildAsrAudioFrames(Uint8List pcm) {
  const int frameSize = 1280;
  final List<String> frames = <String>[];
  for (int offset = 0; offset < pcm.length; offset += frameSize) {
    final int end =
        offset + frameSize > pcm.length ? pcm.length : offset + frameSize;
    frames.add(base64.encode(pcm.sublist(offset, end)));
  }
  if (frames.isEmpty) {
    frames.add('');
  }
  return frames;
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final Object? key in value.keys) '$key': value[key],
    };
  }
  return <String, dynamic>{};
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

/// 一帧识别结果。text 是本帧新增的字词，done 表示服务端已结束。
class AsrFrame {
  AsrFrame({
    required this.text,
    required this.done,
    required this.code,
    required this.message,
  });

  final String text;
  final bool done;
  final int code;
  final String message;
}

/// 解码 base64 的听写结果 JSON，按 ws[].cw[].w 顺序拼接。
String decodeAsrText(String encoded) {
  if (encoded.isEmpty) {
    return '';
  }
  try {
    final String payload = utf8.decode(base64.decode(encoded));
    final Map<String, dynamic> root = _asMap(jsonDecode(payload));
    final Object? ws = root['ws'];
    if (ws is! List) {
      return '';
    }
    final StringBuffer buffer = StringBuffer();
    for (final Object? item in ws) {
      final Map<String, dynamic> segment = _asMap(item);
      final Object? cw = segment['cw'];
      if (cw is! List) {
        continue;
      }
      for (final Object? word in cw) {
        final Map<String, dynamic> entry = _asMap(word);
        buffer.write((entry['w'] ?? '').toString());
      }
    }
    return buffer.toString();
  } on Object catch (_) {
    return '';
  }
}

/// 解析 ASR 服务端帧。
AsrFrame parseAsrMessage(String message) {
  Object? decoded;
  try {
    decoded = jsonDecode(message);
  } on Object catch (_) {
    return AsrFrame(
      text: '',
      done: true,
      code: -1,
      message: '识别响应不是 JSON',
    );
  }
  final Map<String, dynamic> root = _asMap(decoded);
  final Map<String, dynamic> header = _asMap(root['header']);
  final int code = _asInt(header['code']) ?? 0;
  final String errorMessage = (header['message'] ?? '').toString();
  if (code != 0) {
    return AsrFrame(text: '', done: true, code: code, message: errorMessage);
  }
  final Map<String, dynamic> result =
      _asMap(_asMap(root['payload'])['result']);
  return AsrFrame(
    text: decodeAsrText((result['text'] ?? '').toString()),
    done: _asInt(header['status']) == 2 || _asInt(result['status']) == 2,
    code: 0,
    message: errorMessage,
  );
}

/// 合成请求。aue=lame 返回 mp3（可直接播放），raw 返回 16k PCM（便于喂回 ASR 自测）。
String buildTtsRequest({
  required String appId,
  required String vcn,
  required String text,
  bool mp3 = true,
}) {
  return jsonEncode(<String, Object>{
    'common': <String, Object>{'app_id': appId},
    'business': <String, Object>{
      'aue': mp3 ? 'lame' : 'raw',
      if (mp3) 'sfl': 1,
      'auf': 'audio/L16;rate=16000',
      'vcn': vcn,
      // 小语种（维吾尔文）必须用 UTF8，中英文同样可用。
      'tte': 'UTF8',
      'speed': 50,
      'volume': 50,
      'pitch': 50,
      'bgs': 0,
    },
    'data': <String, Object>{
      'status': 2,
      'text': base64.encode(utf8.encode(text)),
    },
  });
}

/// 一帧合成结果。
class TtsFrame {
  TtsFrame({
    required this.audio,
    required this.done,
    required this.code,
    required this.message,
  });

  final Uint8List audio;
  final bool done;
  final int code;
  final String message;
}

/// 解析 TTS 服务端帧。code=0 且 data 为空的帧按文档直接忽略。
TtsFrame parseTtsMessage(String message) {
  Object? decoded;
  try {
    decoded = jsonDecode(message);
  } on Object catch (_) {
    return TtsFrame(
      audio: Uint8List(0),
      done: true,
      code: -1,
      message: '合成响应不是 JSON',
    );
  }
  final Map<String, dynamic> root = _asMap(decoded);
  final int code = _asInt(root['code']) ?? 0;
  final String errorMessage = (root['message'] ?? '').toString();
  if (code != 0) {
    return TtsFrame(
      audio: Uint8List(0),
      done: true,
      code: code,
      message: errorMessage,
    );
  }
  final Map<String, dynamic> data = _asMap(root['data']);
  final String encoded = (data['audio'] ?? '').toString();
  Uint8List audio = Uint8List(0);
  if (encoded.isNotEmpty) {
    try {
      audio = Uint8List.fromList(base64.decode(encoded));
    } on Object catch (_) {
      audio = Uint8List(0);
    }
  }
  return TtsFrame(
    audio: audio,
    done: _asInt(data['status']) == 2,
    code: 0,
    message: errorMessage,
  );
}

/// 讯飞合成常见错误码的可操作提示。
///
/// 服务端 message 往往只有「参数错误」这种模糊字样，真正原因（发音人没买、
/// 当天额度用完）只能靠错误码区分，所以直接把码翻成人能看懂的话。
String ttsHint(int code) {
  switch (code) {
    case 11200:
      return ' · 该发音人未授权或语音合成服务未开通（控制台 → 发音人管理）';
    case 11201:
      return ' · 当天调用量已超限';
    case 10105:
      return ' · 参数不合法：多为 vcn 填错或文本编码不对';
    case 10106:
      return ' · 请求参数过长（单次合成字数超限）';
    case 10003:
      return ' · 访问上游超时，稍后重试';
    default:
      return '';
  }
}

/// 讯飞语音端口：实现 conversation.dart 里的 SpeechPort 接口。
class XfyunSpeechPort implements SpeechPort {
  XfyunSpeechPort({
    SpeechConfig? config,
    XfyunSocketOpener? opener,
    XfyunDateBuilder? dateBuilder,
    this.frameDelay = const Duration(milliseconds: 40),
    this.ttsMp3 = true,
  })  : config = config ?? speechConfig,
        opener = opener ?? openXfyunSocket,
        dateBuilder = dateBuilder ??
            (() => buildXfyunDate(DateTime.now().toUtc()));

  final SpeechConfig config;
  final XfyunSocketOpener opener;
  final XfyunDateBuilder dateBuilder;

  /// 分包发送间隔。一帧 1280 字节正好是 16k/16bit 单声道的 40ms，官方要求
  /// 按这个实时率上传。之前用 10ms（4 倍速灌）在 CI 的干净合成音频上能过，
  /// 真机录音更长、带环境噪声时服务端容易只吃到前半段，返回空识别结果。
  final Duration frameDelay;

  /// 合成结果格式。CI live check 用 false 拿到 16k PCM，直接喂回 ASR 做闭环。
  final bool ttsMp3;

  static const String asrHost = 'iat.cn-huabei-1.xf-yun.com';
  static const String asrPath = '/v1';
  static const String ttsHost = 'tts-api.xfyun.cn';
  static const String ttsPath = '/v2/tts';

  @override
  bool get isAvailable => config.hasConfig;

  Uri _uri({required bool isAsr, required String date}) {
    final String custom = config.endpoint.trim();
    if (custom.isNotEmpty) {
      // NAS 代理：代理自己保管 APISecret 并按 path 转发，App 侧不用鉴权。
      final Uri parsed = Uri.parse(custom);
      return parsed.replace(
        path: isAsr ? asrPath : ttsPath,
        queryParameters: <String, String>{
          ...parsed.queryParameters,
          'kind': isAsr ? 'asr' : 'tts',
        },
      );
    }
    return buildXfyunUri(
      host: isAsr ? asrHost : ttsHost,
      path: isAsr ? asrPath : ttsPath,
      date: date,
      apiKey: config.apiKey.trim(),
      apiSecret: config.apiSecret.trim(),
    );
  }

  String _languageCode(Language language) =>
      language == Language.uyghur ? 'ug' : 'zh';

  @override
  Future<String> listen(Uint8List audio, Language language) async {
    config.lastDiagnostic = '';
    if (!config.hasConfig) {
      throw const SpeechException('语音服务未配置');
    }
    if (audio.isEmpty) {
      throw const SpeechException('没有录到声音');
    }
    final Uri uri = _uri(isAsr: true, date: dateBuilder());
    final XfyunSocket socket = await opener(uri);
    final StringBuffer transcript = StringBuffer();
    final Completer<String> done = Completer<String>();
    StreamSubscription<String>? subscription;
    try {
      subscription = socket.messages.listen(
        (String message) {
          final AsrFrame frame = parseAsrMessage(message);
          if (frame.code != 0 && !done.isCompleted) {
            done.completeError(
                SpeechException('识别失败 ${frame.code}: ${frame.message}'));
            return;
          }
          transcript.write(frame.text);
          if (frame.done && !done.isCompleted) {
            done.complete(transcript.toString());
          }
        },
        onError: (Object error) {
          if (!done.isCompleted) {
            done.completeError(error);
          }
        },
      );

      final List<String> frames = buildAsrAudioFrames(audio);
      final String ln = _languageCode(language);
      final String appId = config.appId.trim();
      socket.send(buildAsrFirstFrame(
        appId: appId,
        ln: ln,
        audio: frames.first,
      ));
      for (int index = 1; index < frames.length; index++) {
        if (frameDelay > Duration.zero) {
          await Future<void>.delayed(frameDelay);
        }
        socket.send(buildAsrAudioFrame(
          appId: appId,
          status: 1,
          audio: frames[index],
          seq: index + 1,
        ));
      }
      socket.send(buildAsrAudioFrame(
        appId: appId,
        status: 2,
        audio: '',
        seq: frames.length + 1,
      ));

      // 发帧本身就是实时率，超时预算要把上传时间算进去，否则长按一句话
      // 还没发完就被掐断，界面只会显示「识别超时」，看不出是长度问题。
      final int sendMs = frames.length * frameDelay.inMilliseconds;
      final String text = (await done.future.timeout(
        Duration(milliseconds: 25000 + sendMs),
        onTimeout: () => throw const SpeechException('识别超时（网络或服务端无响应）'),
      ))
          .trim();
      if (text.isEmpty) {
        // 音频确实发出去了，但云端一个字都没回。给出上传时长，配合界面上的
        // 「录音 x.x s / 峰值 xx%」就能直接分清是麦克风没声还是识别参数不对。
        final double seconds = audio.lengthInBytes / 32000;
        throw SpeechException(
            '云端没识别出文字（已上传 ${seconds.toStringAsFixed(1)}s 音频）'
            ' · 靠近话筒说完整一句，并确认顶部源语言与你说的话一致');
      }
      config.lastDiagnostic = '';
      return text;
    } on Object catch (error) {
      config.lastDiagnostic = _diagnose(error);
      rethrow;
    } finally {
      await subscription?.cancel();
      await socket.close();
    }
  }

  @override
  Future<Uint8List> speak(String text, Language language) async {
    config.lastDiagnostic = '';
    if (!config.hasConfig) {
      throw const SpeechException('语音服务未配置');
    }
    final bool isUyghur = language == Language.uyghur;
    final String vcn =
        isUyghur ? config.ugVcn.trim() : config.zhVcn.trim();
    if (vcn.isEmpty) {
      throw SpeechException(isUyghur
          ? '维语发音人 vcn 未配置 · 到设置页填讯飞「发音人管理」里的维吾尔语发音人'
          : '中文发音人 vcn 未配置 · 到设置页填写');
    }
    if (text.trim().isEmpty) {
      return Uint8List(0);
    }

    final Uri uri = _uri(isAsr: false, date: dateBuilder());
    final XfyunSocket socket = await opener(uri);
    final BytesBuilder audio = BytesBuilder(copy: false);
    final Completer<Uint8List> done = Completer<Uint8List>();
    StreamSubscription<String>? subscription;
    try {
      subscription = socket.messages.listen(
        (String message) {
          final TtsFrame frame = parseTtsMessage(message);
          if (frame.code != 0 && !done.isCompleted) {
            done.completeError(SpeechException(
                '合成失败 ${frame.code}: ${frame.message}${ttsHint(frame.code)}'));
            return;
          }
          audio.add(frame.audio);
          if (frame.done && !done.isCompleted) {
            done.complete(audio.takeBytes());
          }
        },
        onError: (Object error) {
          if (!done.isCompleted) {
            done.completeError(error);
          }
        },
      );
      socket.send(buildTtsRequest(
        appId: config.appId.trim(),
        vcn: vcn,
        text: text.trim(),
        mp3: ttsMp3,
      ));
      final Uint8List result = await done.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw const SpeechException('合成超时（25 秒）'),
      );
      if (result.isEmpty) {
        throw SpeechException(isUyghur
            ? '维语合成返回空音频 · 该发音人可能未在控制台开通或额度用尽'
            : '中文合成返回空音频 · 该发音人可能未在控制台开通或额度用尽');
      }
      config.lastDiagnostic = '';
      return result;
    } on Object catch (error) {
      config.lastDiagnostic = _diagnose(error);
      rethrow;
    } finally {
      await subscription?.cancel();
      await socket.close();
    }
  }

  /// 只保留异常描述，绝不把带鉴权参数的 URL 或请求体写进 UI / 日志。
  static String _diagnose(Object error) {
    final String raw = error.toString();
    final int marker = raw.indexOf('wss://');
    final String clean = marker >= 0 ? raw.substring(0, marker).trim() : raw;
    return clean.length <= 200 ? clean : '${clean.substring(0, 200)}…';
  }
}
