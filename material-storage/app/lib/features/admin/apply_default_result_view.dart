/// 应用默认结果视图(B8 功能点 5 拆件;web ApplyDefaultModal 结果态移动版):
/// 汇总 Alert(部分成功/刷新完成)+ 逐项目行({applied, skipped_stale} /
/// error,失败不阻塞其余)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
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
    final failed = result.failedCount;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('刷新默认权限 — 结果',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: failed > 0
                      ? Tk.accentFaint
                      : Tk.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  failed > 0
                      ? '部分成功:${result.results.length - failed} 个项目已刷新,'
                          '$failed 个失败;成功项共补写 ${result.totalApplied} 条授权、'
                          '跳过 ${result.totalSkipped} 条过期条目;失败项可稍后重试。'
                      : '刷新完成:共补写 ${result.totalApplied} 条授权,'
                          '跳过 ${result.totalSkipped} 条过期条目',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: failed > 0 ? Tk.amber : Tk.green,
                      height: 1.5),
                ),
              ),
              const SizedBox(height: 8),
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
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Tk.fill,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5)),
                        ),
                        if (r.isFailed)
                          Flexible(
                            child: Text('失败:${r.error}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11, color: Tk.red)),
                          )
                        else ...[
                          Text('补写 ${r.applied ?? 0}',
                              style: const TextStyle(
                                  fontSize: 11.5, color: Tk.muted)),
                          const SizedBox(width: 8),
                          Text('跳过过期 ${r.skippedStale ?? 0}',
                              style: const TextStyle(
                                  fontSize: 11.5, color: Tk.muted)),
                        ],
                      ]),
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
