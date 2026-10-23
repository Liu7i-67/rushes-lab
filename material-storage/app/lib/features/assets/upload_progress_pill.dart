/// UploadProgressPill — 宫格上传进度胶囊(F8):底部导航上方(Flutter 推入页
/// 无导航时落在 FAB 上方/SafeArea 之上);暖炭底 #383228 胶囊、左侧金色 sync
/// 图标、中间「正在上传 N 项」、右侧 3px 金色进度条,整条点击切传输页。
/// 两种主题下都保持深色(浮层惯例);[UploadMiniBar] 为兼容旧 API 的转发件。
library;

import 'package:flutter/material.dart';

import '../../core/transfers/transfer_queue.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../theme/tk_colors.dart';

class UploadProgressPill extends StatelessWidget {
  const UploadProgressPill({super.key, this.queue, this.onTap});

  /// 测试注入用;默认全局单例。
  final TransferQueue? queue;

  /// 整条点击回调(宫格页接 openTransfersView);null=纯展示不可点。
  final VoidCallback? onTap;

  // 固定深色表面(§4.3 预览/浮层惯例),不随主题切换。
  static const Color _bg = Color(0xFF383228);
  static const Color _fg = Color(0xFFF3EDDF);
  static const Color _border = Color(0x12FFFFFF);
  static const Color _track = Color(0x2EFFFFFF);

  @override
  Widget build(BuildContext context) {
    final q = queue ?? TransferQueue.I;
    return AnimatedBuilder(
      animation: q,
      builder: (context, _) {
        final active = q.activeUploadCount;
        if (active == 0) return const SizedBox.shrink();
        return Semantics(
          button: onTap != null,
          label: '正在上传 $active 项,查看传输',
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Tk.rPill),
              boxShadow: TkColors.dark.shadow2,
            ),
            child: Material(
              color: _bg,
              clipBehavior: Clip.antiAlias,
              shape: const StadiumBorder(side: BorderSide(color: _border)),
              child: InkWell(
                onTap: onTap,
                customBorder: const StadiumBorder(),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.sync, size: 16, color: Tk.previewGold),
                      const SizedBox(width: 9),
                      Text(
                        '正在上传 $active 项',
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: _fg,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: q.uploadByteProgress,
                            minHeight: 3,
                            backgroundColor: _track,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Tk.previewGold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 兼容旧 API:宫格/测试既有 `UploadMiniBar(queue:, onTap:)` 调用转发到新胶囊。
class UploadMiniBar extends StatelessWidget {
  const UploadMiniBar({super.key, this.queue, this.onTap});

  final TransferQueue? queue;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) =>
      UploadProgressPill(queue: queue, onTap: onTap);
}

/// 宫格 body Stack 内的定位包装(left/right 20 / 指定 bottom),把胶囊浮层
/// 从页面编排里收拢到上传件本身。
class UploadPillOverlay extends StatelessWidget {
  const UploadPillOverlay({
    super.key,
    required this.bottom,
    this.queue,
    this.onTap,
  });

  final double bottom;
  final TransferQueue? queue;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Positioned(
    left: Tk.spacePage,
    right: Tk.spacePage,
    bottom: bottom,
    child: UploadProgressPill(queue: queue, onTap: onTap),
  );
}

/// 金色胶囊上传 FAB(F8):金底深墨字、pill、shadow2;tooltip 固定「上传」。
class AssetsUploadFab extends StatelessWidget {
  const AssetsUploadFab({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Tk.rPill),
        boxShadow: tk.shadow2,
      ),
      child: FloatingActionButton.extended(
        tooltip: '上传',
        onPressed: onPressed,
        backgroundColor: tk.gold,
        foregroundColor: const Color(0xFF1A1509),
        elevation: 0,
        highlightElevation: 0,
        shape: const StadiumBorder(),
        icon: const Icon(Icons.upload_outlined, size: 20),
        label: const Text(
          '上传',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
