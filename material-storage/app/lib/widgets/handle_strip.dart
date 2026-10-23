/// HandleStrip — 自制拖拽把手条(app-polish-3 自 new_project_sheet.dart 抽出,
/// 原私有 _HandleStrip;D2 引入):框架 showDragHandle 的下滑关闭走
/// Navigator.pop 直呼,PopScope 拦不住 → 自绘把手承接下滑手势,与关闭钮/
/// 返回键同走调用方的关闭守卫流。全宽 + 纵向 12 触控余量(测试自 sheet 顶
/// +24 下滑须命中);累计位移超阈值(80)或下甩速度超阈值(500)即触发。
library;

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

/// sheet 顶部把手条;onDismiss 由调用方接关闭守卫(确认/直关自定)。
class HandleStrip extends StatefulWidget {
  const HandleStrip({super.key, required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  State<HandleStrip> createState() => _HandleStripState();
}

class _HandleStripState extends State<HandleStrip> {
  var _dy = 0.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dy = 0,
      onVerticalDragUpdate: (d) => _dy += d.primaryDelta ?? 0,
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_dy > 80 || v > 500) widget.onDismiss();
      },
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: Tk.spaceMd),
          width: 38,
          height: 4,
          decoration: BoxDecoration(
            color: context.tk.lineStrong,
            borderRadius: BorderRadius.circular(Tk.rPill),
          ),
        ),
      ),
    );
  }
}
