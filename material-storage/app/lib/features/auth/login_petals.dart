/// 登录页桃花瓣层(§8.1 / F5 / F15)——自绘、无依赖、可降级。
///
/// 22 片、尺寸 12–27、透明度 40%–77%,从右上向左下飘落;横向 sin 摆动、
/// 自转、纵向压扁模拟翻面(0.42+0.58|cos|)。每片轮廓/叶脉 Path 与径向
/// Shader/Paint 只在建场或换主题时构建,动画帧只做 save/translate/rotate/
/// scale + drawPath;AnimationController.unbounded 由线性 Simulation 驱动,
/// `repaint` 直接挂 CustomPainter,不做整树 setState。
/// MediaQuery.disableAnimations 时不启动 ticker,仅画 staticCount 片静态花瓣;
/// dispose 停表,离开登录页自然销毁。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

typedef _Palette = ({Color light, Color deep});
typedef _Paints = ({Paint fill, Paint stroke, Paint vein});

const List<_Palette> _darkPalettes = [
  (light: Color(0xFFF6CFC7), deep: Color(0xFFD97F80)),
  (light: Color(0xFFF8DAD2), deep: Color(0xFFE09A96)),
  (light: Color(0xFFEFB3AE), deep: Color(0xFFC96E72)),
];

const List<_Palette> _lightPalettes = [
  (light: Color(0xFFF4CDC4), deep: Color(0xFFCE7C7B)),
  (light: Color(0xFFF8DCD2), deep: Color(0xFFD98C86)),
  (light: Color(0xFFEDB2AC), deep: Color(0xFFC06466)),
];

/// 登录页背景之上的桃花层(不拦截触控由调用方包 IgnorePointer)。
class LoginPetals extends StatefulWidget {
  const LoginPetals({super.key, this.count = 22, this.staticCount = 8});

  /// 动画模式花瓣数(§8.1:22)。
  final int count;

  /// reduced-motion 下静态展示的花瓣数。
  final int staticCount;

  @override
  State<LoginPetals> createState() => _LoginPetalsState();
}

/// 线性时间源:controller.value = 已运行秒数(永不结束)。
class _PetalSimulation extends Simulation {
  _PetalSimulation();

  @override
  double x(double time) => time;

  @override
  double dx(double time) => 1;

  @override
  bool isDone(double time) => false;
}

class _LoginPetalsState extends State<LoginPetals>
    with SingleTickerProviderStateMixin {
  final _random = math.Random();
  List<_Petal> _petals = const [];
  List<_PetalSprite> _sprites = const [];
  List<_Palette> _palettes = _darkPalettes;
  Size _scene = Size.zero;
  Brightness? _brightness;
  bool? _reduceMotion;
  AnimationController? _controller;
  double _last = 0;
  double _time = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (brightness != _brightness) {
      _brightness = brightness;
      _palettes = brightness == Brightness.dark
          ? _darkPalettes
          : _lightPalettes;
      _sprites = _buildSprites();
      for (final p in _petals) {
        p.paints = _paints(_palettes[p.paletteIndex], p.alpha);
      }
    }
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _scene = Size.zero; // 下次 build 按新模式重新建场
      if (reduce) {
        _stop();
      } else {
        _start();
      }
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    if (_controller != null) return;
    final controller = AnimationController.unbounded(vsync: this)
      ..addListener(_onFrame);
    _controller = controller;
    _last = 0;
    controller.animateWith(_PetalSimulation());
  }

  void _stop() {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onFrame);
    controller.dispose();
  }

  void _onFrame() {
    final controller = _controller;
    if (controller == null || _scene == Size.zero) return;
    final value = controller.value;
    final dt = (value - _last).clamp(0.0, 0.05);
    _last = value;
    if (dt <= 0) return;
    _time += dt;
    for (final p in _petals) {
      p.phase += dt * 1.1;
      p.x += (p.vx + math.sin(p.phase) * p.amp) * dt;
      p.y += p.vy * dt;
      p.rot += p.vr * dt;
      p.fold = 0.42 + 0.58 * math.cos(_time * 1.35 + p.flip).abs();
      if (p.y > _scene.height + 40 || p.x < -50) _respawn(p);
    }
  }

  /// 按当前画布建场;尺寸不变时保留原花瓣(换主题只重建 Paint)。
  void _seedScene(Size size) {
    if (size == _scene || size.isEmpty) return;
    _scene = size;
    final count = _reduceMotion == true ? widget.staticCount : widget.count;
    _petals = List.generate(count, (i) => _spawn(initial: true, index: i));
  }

  _Petal _spawn({required bool initial, int index = 0, _Petal? target}) {
    final r = _random;
    final static = _reduceMotion == true;
    final w = _scene.width;
    final h = _scene.height;
    final p =
        target ??
        _Petal(alpha: 0.40 + r.nextDouble() * 0.37, fold: static ? 0.7 : 1);
    p
      ..size = 12 + r.nextDouble() * 15
      ..x = static
          ? w * (0.42 + 0.16 * (index % 4))
          : w * (0.28 + r.nextDouble() * 0.95)
      ..y = static
          ? h * (0.10 + 0.18 * (index ~/ 4)) + 6.0 * (index % 3)
          : (initial ? r.nextDouble() * h : -30 - r.nextDouble() * 160)
      ..vx = -(11 + r.nextDouble() * 20)
      ..vy = 24 + r.nextDouble() * 30
      ..rot = r.nextDouble() * math.pi * 2
      ..vr = (r.nextDouble() - 0.5) * 0.9
      ..phase = r.nextDouble() * math.pi * 2
      ..flip = r.nextDouble() * math.pi * 2
      ..amp = 9 + r.nextDouble() * 12
      ..sprite = r.nextInt(6);
    if (static) p.fold = 0.55 + r.nextDouble() * 0.4;
    return p..paints = _paints(_palettes[p.paletteIndex], p.alpha);
  }

  /// 落出画布后从右上方重生(重置轨迹与精灵,保留透明度)。
  void _respawn(_Petal p) => _spawn(initial: false, target: p);

  List<_PetalSprite> _buildSprites() => [
    for (final _ in _palettes) ...[
      _PetalSprite(narrow: false),
      _PetalSprite(narrow: true),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isFinite) _seedScene(size);
        return RepaintBoundary(
          child: CustomPaint(
            painter: _PetalPainter(
              petals: _petals,
              sprites: _sprites,
              repaint: _controller,
            ),
          ),
        );
      },
    );
  }
}

class _Petal {
  _Petal({required this.alpha, required this.fold});

  double size = 0, x = 0, y = 0, vx = 0, vy = 0, rot = 0, vr = 0;
  double phase = 0, flip = 0, amp = 0, fold;
  final double alpha;
  int sprite = 0;
  late _Paints paints;

  /// 6 个精灵 = 3 配色 × (常规, 窄瓣)。
  int get paletteIndex => sprite ~/ 2;
}

/// 花瓣轮廓/叶脉(96×96 局部坐标,中心 0,0;对齐原型 makePetalSprite)。
class _PetalSprite {
  _PetalSprite({required bool narrow}) {
    final k = narrow ? 0.82 : 1.0;
    _path
      ..moveTo(0, 34)
      ..cubicTo(-26 * k, 28, -33 * k, -4, -19 * k, -27)
      ..quadraticBezierTo(-12 * k, -37, -8 * k, -35)
      ..quadraticBezierTo(0, -24, 8 * k, -35)
      ..quadraticBezierTo(12 * k, -37, 19 * k, -27)
      ..cubicTo(33 * k, -4, 26 * k, 28, 0, 34)
      ..close();
    _veins
      ..moveTo(0, 27)
      ..quadraticBezierTo(1, 0, 0, -22)
      ..moveTo(0, 20)
      ..quadraticBezierTo(-10 * k, 2, -18 * k, -14)
      ..moveTo(0, 20)
      ..quadraticBezierTo(10 * k, 2, 18 * k, -14);
  }

  final Path _path = Path();
  final Path _veins = Path();
}

/// 径向渐变(浅→深,中心偏上)+ 半透明白描边/叶脉;每片 alpha 预混进颜色。
_Paints _paints(_Palette palette, double alpha) {
  final shader = RadialGradient(
    center: const Alignment(0, -10 / 48),
    radius: 0.5,
    colors: [
      palette.light.withValues(alpha: alpha),
      palette.light.withValues(alpha: alpha),
      palette.deep.withValues(alpha: alpha),
    ],
    stops: const [0, 0.62, 1],
  ).createShader(Rect.fromLTWH(-48, -48, 96, 96));
  return (
    fill: Paint()..shader = shader,
    stroke: Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: alpha * 0.2),
    vein: Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.white.withValues(alpha: alpha * 0.38),
  );
}

class _PetalPainter extends CustomPainter {
  _PetalPainter({required this.petals, required this.sprites, super.repaint});

  final List<_Petal> petals;
  final List<_PetalSprite> sprites;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in petals) {
      final sprite = sprites[p.sprite];
      final scale = p.size / 72;
      canvas.save();
      canvas.translate(p.x, p.y);
      canvas.rotate(p.rot);
      canvas.scale(scale, scale * p.fold);
      canvas.drawPath(sprite._path, p.paints.fill);
      canvas.drawPath(sprite._path, p.paints.stroke);
      canvas.drawPath(sprite._veins, p.paints.vein);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _PetalPainter oldDelegate) =>
      oldDelegate.petals != petals || oldDelegate.sprites != sprites;
}
