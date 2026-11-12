// 真机录音与播放。抽象端口让 widget 测试可以注入假实现，不触碰平台通道。
//
// 录音格式固定 16k / 16bit / 单声道 PCM，与讯飞 ASR 接口要求一致；
// 播放写系统临时目录后用 audioplayers 播 mp3（讯飞 TTS 的 aue=lame）。
//
// 音量：直接对录音流送来的 PCM 块求 RMS，而不是订阅 record 的
// onAmplitudeChanged。理由是真机上这条振幅流在 startStream 模式下时有时无，
// 波形不动会让人误判成「麦克风没识别到声音」；而 PCM 块就在手里，
// 有字节就一定有电平，波形动不动＝录音流有没有在送数据，这才是可靠的诊断。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:record/record.dart';

import 'live_asr.dart';

abstract class AudioPort {
  Future<bool> hasPermission();

  Future<void> startRecord();

  Future<Uint8List> stopRecord();

  Future<void> play(Uint8List audio);

  /// 录音过程中的实时音量，取值 0..1。
  ///
  /// 默认给空流：测试里的假实现不必关心波形，没有这条流时界面退化成
  /// 静默的静态条，不会报错、也不会漏掉任何帧。
  Stream<double> get levels => const Stream<double>.empty();

  /// 最近一段录音的可读诊断（时长 / 字节 / 峰值电平）。
  /// 出问题时把它贴在提示里，用户不用猜是「没录到」还是「录到了没认出」。
  String get recordingDiagnostics => '';

  /// 页面销毁时释放资源。默认什么都不做，假实现无需关心。
  void dispose() {}
}

/// 把 `record` 给出的 dBFS 值换算成 0..1。
///
/// dBFS 是负值：0 表示满幅，-60 以下基本等于安静。实测手机在安静室内
/// 约 -50 ～ -40，正常说话 -30 ～ -12，所以把 -60..0 拉成 0..1 足够用，
/// 再用 sqrt 压一下低端，让小音量也能推出可见的起伏。
double levelFromDb(double db) {
  if (db.isNaN || db.isInfinite) {
    return 0;
  }
  final double normalized = ((db + 60) / 60).clamp(0.0, 1.0).toDouble();
  return math.sqrt(normalized);
}

/// 从一块 16bit 小端 PCM 求 RMS 电平（0..1）。
///
/// record 的 startStream 送来的就是这种裸 PCM，直接在 Dart 里算比再开一条
/// 平台振幅流可靠得多。RMS 换算成 dBFS 后复用 [levelFromDb] 的压缩曲线，
/// 这样波形和之前的手感一致，也不会因为某个平台不给振幅就整条静默。
double levelFromPcm(Uint8List chunk) {
  final int pairs = chunk.lengthInBytes ~/ 2;
  if (pairs == 0) {
    return 0;
  }
  final ByteData data = ByteData.sublistView(chunk);
  double sum = 0;
  for (int i = 0; i < pairs; i++) {
    final int sample = data.getInt16(i * 2, Endian.little);
    sum += sample * sample;
  }
  final double rms = math.sqrt(sum / pairs);
  if (rms < 1) {
    return 0;
  }
  final double db = 20 * math.log(rms / 32768) / math.ln10;
  return levelFromDb(db);
}

/// 在 App 启动时把麦克风权限问下来。
///
/// record 的 hasPermission() 不只是「查」，它会弹系统授权框并等用户点。
/// 若拖到「按住说话」那一刻才问，用户必须松手去点弹窗，松手事件先到、
/// 权限回来后那段录音又被当成「按太快」丢弃 —— 第一次按住必然毫无反应，
/// 看起来就是「识别不到声音」。所以由 main() 在首帧后提前问一次，
/// 之后按住时再问就是幂等的立即返回。
Future<bool> primeMicrophonePermission() async {
  final AudioRecorder recorder = AudioRecorder();
  bool granted = false;
  try {
    granted = await recorder.hasPermission();
  } on Object catch (_) {
    // 启动期失败不弹错：真正按住时 _beginVoice 会再问一次并给可读提示。
    granted = false;
  }
  try {
    await recorder.dispose();
  } on Object catch (error) {
    // 只用来问权限的临时实例，释放失败不影响功能；不重新抛出，
    // 否则会盖掉上面已经拿到的授权结果。
    debugPrint('临时录音器释放失败（不影响功能）：$error');
  }
  return granted;
}

class DeviceAudioPort implements AudioPort, ChunkedAudioPort {
  DeviceAudioPort({AudioRecorder? recorder, AudioPlayer? player})
      : _recorder = recorder ?? AudioRecorder(),
        _player = player ?? AudioPlayer();

  final AudioRecorder _recorder;
  final AudioPlayer _player;
  final List<String> _errors = <String>[];

  StreamSubscription<Uint8List>? _subscription;
  final StreamController<double> _levels = StreamController<double>.broadcast();

  /// 边录边传用：把录音流原样广播出去，页面接上 ASR 会话后，说话的同时
  /// 音频就已经在上传了。broadcast 保证先订阅再 startRecord 也漏不掉开头。
  /// sync: true —— 尾帧必须在 stopRecord() 返回之前就已经交到 ASR 会话手上。
  /// 默认异步投递会把它压进微任务队列，松手后 finish() 先跑就会漏掉最后几个字。
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast(sync: true);

  BytesBuilder? _buffer;
  double _peak = 0;
  DateTime? _startedAt;
  String _diagnostics = '';

  /// 播放前只配置一次音频会话：否则 iOS 静音开关打开、Android 抢不到
  /// 音频焦点时都会「明明合成了音频却一点声音没有」。
  bool _audioContextReady = false;

  /// 录音流偶发错误的摘要，供界面提示（不含音频内容）。
  List<String> get errors => List<String>.unmodifiable(_errors);

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<Uint8List> get pcmChunks => _chunks.stream;

  @override
  String get recordingDiagnostics => _diagnostics;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> startRecord() async {
    _diagnostics = '';
    _peak = 0;
    _startedAt = DateTime.now();
    final Stream<Uint8List> stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    // copy 用默认值 true：平台侧若复用同一块缓冲区，copy:false 会让
    // 最终拼出来的 PCM 变成「最后一块重复 N 次」，云端自然识别不出字。
    final BytesBuilder buffer = BytesBuilder();
    _buffer = buffer;
    _subscription = stream.listen(
      (Uint8List chunk) {
        buffer.add(chunk);
        final double level = levelFromPcm(chunk);
        if (level > _peak) {
          _peak = level;
        }
        if (!_levels.isClosed) {
          _levels.add(level);
        }
        // 同一块 PCM 交给 ASR 会话按 40ms 实时率排队上传。广播流没有订阅者时
        // 这一句就是空转，不会缓冲任何数据。
        if (!_chunks.isClosed && _chunks.hasListener) {
          _chunks.add(chunk);
        }
      },
      onError: (Object error) {
        _errors.add(error.toString());
      },
      cancelOnError: true,
    );
  }

  @override
  Future<Uint8List> stopRecord() async {
    // record 5.2.0 的 stop() 内部会先 cancel 掉底层 EventChannel 订阅，再
    // close 自己的 broadcast controller。所以尾帧必须在 stop「之前」等：
    // 松手那一刻还有几块 PCM 排在平台通道队列里，先让它们投递进 buffer。
    // 顺序写反（stop 之后再等）是一点用都没有的，短句会整段变薄。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _recorder.stop();
    final StreamSubscription<Uint8List>? subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    final BytesBuilder? buffer = _buffer;
    _buffer = null;
    final Uint8List pcm = buffer == null ? Uint8List(0) : buffer.takeBytes();
    final int ms = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inMilliseconds;
    _diagnostics = describeRecording(pcm.lengthInBytes, ms, _peak);
    return pcm;
  }

  /// 把录音统计说成人话。峰值低于 5% 时额外点一句，这是「权限给了、
  /// 流也在跑，但麦克风被静音/占着」最典型的特征。
  static String describeRecording(int bytes, int ms, double peak) {
    if (bytes == 0) {
      return '录音 0 字节（麦克风没有送来数据）';
    }
    final String seconds = (ms / 1000).toStringAsFixed(1);
    final String kb = (bytes / 1024).toStringAsFixed(1);
    final int percent = (peak.clamp(0.0, 1.0) * 100).round();
    final String hint = percent < 5 ? ' · 电平极低，麦克风可能没在收声' : '';
    return '录音 ${seconds}s / ${kb}KB / 峰值 $percent%$hint';
  }

  @override
  Future<void> play(Uint8List audio) async {
    if (audio.isEmpty) {
      return;
    }
    await _ensureAudioContext();
    final Directory directory =
        await Directory.systemTemp.createTemp('weihan_tts_');
    final File file =
        File('${directory.path}${Platform.pathSeparator}speech.mp3');
    await file.writeAsBytes(audio, flush: true);
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> _ensureAudioContext() async {
    if (_audioContextReady) {
      return;
    }
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          // playback 是纯输出分类，一旦全局设上，之后再录音会被系统拒掉；
          // playAndRecord 同时允许输入和输出，配合 defaultToSpeaker 让译文
          // 从扬声器出来（该 option 也只在 playAndRecord 下合法）。
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playAndRecord,
            options: const <AVAudioSessionOptions>{
              AVAudioSessionOptions.defaultToSpeaker,
            },
          ),
          // none = 不主动抢音频焦点。默认是 gain（长期独占），播完也不释放，
          // 下一轮录音可能被自己挤掉。
          android: const AudioContextAndroid(
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.assistant,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
    } on Object catch (error) {
      // 配置失败不阻塞播放：能用默认会话出声就不该因为这次调用整轮失败。
      _errors.add('audioContext: $error');
    }
    _audioContextReady = true;
  }

  /// 页面销毁时释放流控制器（否则热重载会留下一个永远关不掉的 controller）。
  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    if (!_levels.isClosed) {
      _levels.close();
    }
    if (!_chunks.isClosed) {
      _chunks.close();
    }
  }
}
