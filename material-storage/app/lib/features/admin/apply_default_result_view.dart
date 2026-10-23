/// 应用默认结果视图(B8 功能点 5 拆件;web ApplyDefaultModal 结果态移动版):
/// 汇总条(部分成功 warn / 刷新完成 ok)+ 逐项目行({applied, skipped_stale} /
/// error,失败不阻塞其余)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

class ApplyDefaultResultView extends StatelessWidget {
  const ApplyDefaultResultView({
    super.key,
    required this.result,
    required this.projects,
    required this.onDone,
  });

  final ApplyDefaultResult result;

  /// 已加载的全量项目(结果行 id → 项目名;未命中回落 id 片段)。
  final List<Project> projects;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final failed = result.failedCount;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Tk.spacePage,
            0,
            Tk.spacePage,
            Tk.spaceLg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '刷新默认权限 — 结果',
                style: TextStyle(
                  fontSize: Tk.fzSection,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                ),
              ),
              const SizedBox(height: Tk.spaceSm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: failed > 0 ? tk.warnSoft : tk.okSoft,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                  border: Border.all(
                    color: failed > 0
                        ? tk.warn.withValues(alpha: 0.35)
                        : tk.ok.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  failed > 0
                      ? '部分成功:${result.results.length - failed} 个项目已刷新,'
                            '$failed 个失败;成功项共补写 ${result.totalApplied} 条授权、'
                            '跳过 ${result.totalSkipped} 条过期条目;失败项可稍后重试。'
                      : '刷新完成:共补写 ${result.totalApplied} 条授权,'
                            '跳过 ${result.totalSkipped} 条过期条目',
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    color: failed > 0 ? tk.warn : tk.ok,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: Tk.spaceSm),
              Expanded(
                child: ListView.builder(
                  itemCount: result.results.length,
                  itemBuilder: (context, i) {
                    final r = result.results[i];
                    String name = r.projectId.length > 12
                        ? '${r.projectId.substring(0, 12)}…'
                        : r.projectId;
                    for (final p in projects) {
                      if (p.id == r.projectId) {
                        name = p.name;
                        break;
                      }
                    }
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: tk.surface2,
                        borderRadius: BorderRadius.circular(Tk.rSm),
                        border: Border.all(color: tk.line),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                color: tk.ink,
                              ),
                            ),
                          ),
                          if (r.isFailed)
                            Flexible(
                              child: Text(
                                '失败:${r.error}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: Tk.fzMd,
                                  color: tk.danger,
                                ),
                              ),
                            )
                          else ...[
                            Text(
                              '补写 ${r.applied ?? 0}',
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                color: tk.ink3,
                              ),
                            ),
                            const SizedBox(width: Tk.spaceSm),
                            Text(
                              '跳过过期 ${r.skippedStale ?? 0}',
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                color: tk.ink3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: onDone, child: const Text('完成')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
