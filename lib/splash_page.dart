import 'dart:async';

import 'package:flutter/material.dart';

import 'brand_mark.dart';

/// 启动页停留时长。
///
/// 原生启动图只在冷启动那一瞬间顶着白屏；Flutter 一画出第一帧系统就把它撤掉，
/// 所以实测「融合」和两行标语一闪就没了。这里在 Flutter 侧接上同一套视觉，
/// 再稳稳停够这段时间让人读完，然后淡出到对话页。
const Duration kSplashHold = Duration(milliseconds: 2600);

/// 品牌固定色：和 android/.../values/colors.xml、iOS LaunchScreen.storyboard
/// 以及 brand/splash-1080x1920.png 的上下边缘对齐，切换时不会有明显色块接缝。
/// 不跟 AppColors 主题走 —— 启动页是品牌，不是界面配色。
const Color _splashTop = Color(0xFF14586B);
const Color _splashBottom = Color(0xFF062538);
const Color _splashTeal = Color(0xFF8FD9D0);
const Color _splashAmber = Color(0xFFFFC879);

/// 把 [child] 挡在启动页后面，[hold] 到点后淡出。
///
/// 用一次性 [Timer] 而不是无限动画：测试里 pumpAndSettle 能正常收敛。
/// [onFinished] 留给麦克风预授权这类系统级动作，避免授权框盖住要读的文字。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.child,
    this.hold = kSplashHold,
    this.onFinished,
  });

  final Widget child;
  final Duration hold;
  final VoidCallback? onFinished;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _showSplash = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.hold, _finish);
  }

  void _finish() {
    if (!mounted) {
      return;
    }
    setState(() => _showSplash = false);
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      // 默认 layoutBuilder 用 StackFit.loose，全屏 Scaffold 会拿不到紧约束；
      // 这里强制 expand，两层都能铺满整屏，淡入淡出才不会露出白边。
      layoutBuilder: (Widget? current, List<Widget> previous) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ...previous,
            if (current != null) current,
          ],
        );
      },
      child: _showSplash
          ? const SplashView(key: ValueKey<String>('splash-view'))
          : KeyedSubtree(
              key: const ValueKey<String>('app-view'),
              child: widget.child,
            ),
    );
  }
}

/// 应用内启动页：把 brand/splash-1080x1920.png 的内容用矢量 + 文字重画一遍。
///
/// 不塞那张 1.4MB 位图进包，文字还能按屏幕密度保持锐利 —— 用户要看清的
/// 正是这两行标语。布局和成图一致：深青渐变、居中图标、名称、拼音、分隔星、
/// 双语标语、英文副题，底部三点与落款。
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[_splashTop, _splashBottom],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment(0, -0.12),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 26),
                child: _SplashCenter(),
              ),
            ),
            Align(
              alignment: Alignment(0, 0.9),
              child: _SplashFooter(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplashCenter extends StatelessWidget {
  const _SplashCenter();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                const Color(0xFF214A58),
                Color.lerp(const Color(0xFF214A58), Colors.black, 0.32) ??
                    const Color(0xFF17343F),
              ],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withOpacity(0.22),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Center(child: BrandMark(size: 62)),
        ),
        const SizedBox(height: 26),
        const Text(
          '融合',
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w700,
            letterSpacing: 6,
            color: Colors.white,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'R O N G H E',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 4.5,
            color: _splashTeal,
          ),
        ),
        const SizedBox(height: 30),
        const _SplashDivider(),
        const SizedBox(height: 30),
        const Text(
          '让您和您的民族朋友',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            height: 1.6,
            color: Colors.white,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        const Text.rich(
          TextSpan(
            children: <TextSpan>[
              TextSpan(
                text: '沟通',
                style: TextStyle(color: Colors.white),
              ),
              TextSpan(
                text: '不再有障碍',
                style: TextStyle(
                  color: _splashAmber,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            style: TextStyle(fontSize: 17, height: 1.6, letterSpacing: 0.6),
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        const Text(
          'BRIDGING EVERY CONVERSATION',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.2,
            color: _splashTeal,
          ),
        ),
      ],
    );
  }
}

/// 中间那颗四角星与两侧细线。成图里的装饰，用纯几何画，不引图片。
class _SplashDivider extends StatelessWidget {
  const _SplashDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(width: 42, height: 1, color: _splashTeal.withOpacity(0.42)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Icon(Icons.auto_awesome, size: 13, color: _splashAmber),
        ),
        Container(width: 42, height: 1, color: _splashTeal.withOpacity(0.42)),
      ],
    );
  }
}

class _SplashFooter extends StatelessWidget {
  const _SplashFooter();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _dot(_splashTeal.withOpacity(0.65), 5),
            _dot(_splashAmber, 7),
            _dot(Colors.white.withOpacity(0.8), 5),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '语言无界 · 心意相通',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 2.4,
            color: Colors.white.withOpacity(0.55),
          ),
        ),
      ],
    );
  }

  Widget _dot(Color color, double size) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
