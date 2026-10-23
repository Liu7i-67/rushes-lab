/// admin 列表滚动到底自动加载(app-polish F6,方案 §决策3):
/// 「加载更多」按钮式分页 → ScrollController 到底自动加载 + 底部指示器。
/// - AutoLoadScroll:State 混入,持 ScrollController 并监听接近底部
///   (threshold 提前量)触发 [onAutoLoad];节流/去重由页面自身判定
///   (hasMore/loadingMore 守卫),混入只负责「何时喊」。
/// - AutoLoadFooter:底部指示器——加载中转圈行;静止态为轻量可点行
///   (失败 toast 后滚动可再次触发,也可直接点它重试)。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

/// 接近底部提前量(px):到底前 n px 即预加载,滚动连贯无停顿感。
const kAutoLoadThreshold = 240.0;

mixin AutoLoadScroll<T extends StatefulWidget> on State<T> {
  /// 列表滚动控制器(页面 ListView.controller 注入)。
  final ScrollController scrollController = ScrollController();

  /// 到底回调(页面实现:自行守卫 loadingMore/hasMore 后调加载)。
  void onAutoLoad();

  void _handleScroll() {
    final position = scrollController.position;
    if (position.maxScrollExtent - position.pixels <= kAutoLoadThreshold) {
      onAutoLoad();
    }
  }

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    scrollController.removeListener(_handleScroll);
    scrollController.dispose();
    super.dispose();
  }
}

/// 列表底部自动加载指示器(页尾占位项):加载中转圈;静止可点重试。
class AutoLoadFooter extends StatelessWidget {
  const AutoLoadFooter({
    super.key,
    required this.loading,
    this.onTap,
    this.label = '加载更多',
  });

  /// 是否正在加载(转圈态)。
  final bool loading;

  /// 静止态点击回调(重试;null 则仅占位不可点)。
  final VoidCallback? onTap;

  final String label;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 48,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: Tk.spaceSm),
              Text('加载中…', style: TextStyle(fontSize: Tk.fzSm)),
            ],
          ),
        ),
      );
    }
    final tk = context.tk;
    return SizedBox(
      height: 48,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Text(
            label,
            style: TextStyle(fontSize: Tk.fzSm, color: tk.ink3),
          ),
        ),
      ),
    );
  }
}
