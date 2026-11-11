// 音量映射单测：把 record 的 dBFS 换算成界面用的 0..1。
//
// 这段换算决定了波形「跳不跳」：dBFS 是负值，直接取绝对值会得到一堆
// 十几的大数，clamp 之后永远满格；反过来不压缩低端，正常说话只剩 0.2，
// 条条几乎不动。所以把边界钉死在测试里。

import 'package:flutter_test/flutter_test.dart';
import 'package:uyghur_interpreter/device_audio.dart';

void main() {
  test('满幅（0 dBFS）对应 1', () {
    expect(levelFromDb(0), 1.0);
  });

  test('安静到 -60 dBFS 以下对应 0', () {
    expect(levelFromDb(-60), 0.0);
    expect(levelFromDb(-90), 0.0);
  });

  test('正常说话落在可见区间', () {
    // -30 dBFS 是常见说话音量，映射后应该在腰部偏上，而不是贴地。
    expect(levelFromDb(-30), greaterThan(0.6));
    expect(levelFromDb(-30), lessThan(1.0));
    // -45 dBFS 很轻，但仍应有可分辨的起伏。
    expect(levelFromDb(-45), greaterThan(0.3));
    expect(levelFromDb(-45), lessThan(levelFromDb(-30)));
  });

  test('非法值不抛异常，退化为 0', () {
    expect(levelFromDb(double.nan), 0.0);
    expect(levelFromDb(double.negativeInfinity), 0.0);
    expect(levelFromDb(double.infinity), 0.0);
  });

  test('单调不减', () {
    double previous = -1;
    for (int db = -80; db <= 0; db += 5) {
      final double value = levelFromDb(db.toDouble());
      expect(value, greaterThanOrEqualTo(previous));
      previous = value;
    }
  });
}
