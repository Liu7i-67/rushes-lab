/// ProjectGrantsOverview — 项目授权总览(B6 #138;自 project_members_sheet.dart
/// 拆分):审批/邀请获得的 explicit/invited grant 列表 + 四元组撤回。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/toast.dart';

/// 打开项目成员管理面板时挂载;刷新经 [reloadKey] 变化驱动(父侧 setState)。
class ProjectGrantsOverview extends StatefulWidget {
  const ProjectGrantsOverview({super.key, required this.project});

  final Project project;

  @override
  State<ProjectGrantsOverview> createState() => _ProjectGrantsOverviewState();
}

class _ProjectGrantsOverviewState extends State<ProjectGrantsOverview> {
  late Future<List<ProjectGrantRow>> _grants = _load();

  Future<List<ProjectGrantRow>> _load() =>
      session.api!.projectsOps.listGrants(widget.project.id);

  String _objectLabel(String objectType) => switch (objectType) {
        'project' => '整个项目',
        'folder' => '文件夹',
        'sensitive_folder' => '敏感目录',
        _ => objectType,
      };

  Future<void> _revokeGrant(ProjectGrantRow g) async {
    final scope = g.objectName ?? _objectLabel(g.objectType);
    // E14:确认统一 showAppConfirm(danger)
    final ok = await showAppConfirm(
      context,
      title: '撤回此授权?',
      content: '将撤回 ${g.name ?? g.subjectId} 对「$scope」的'
          '${g.level} 授权${g.permanent ? ',对方将立即失去访问' : ''}',
      confirmLabel: '撤回',
      danger: true,
    );
    if (ok != true) return;
    try {
      await session.api!.projectsOps.revokeGrant(
        widget.project.id,
        objectType: g.objectType,
        objectId: g.objectId,
        subject: g.subject,
        relation: g.relation,
      );
      setState(() => _grants = _load());
    } on ApiException catch (e) {
      if (!mounted) return;
      toast(context, '撤回失败:${e.message}', tone: ToastTone.error);
    } catch (e) {
      if (!mounted) return;
      toast(context, errorMessage(e, '撤回失败,请稍后重试'),
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ProjectGrantRow>>(
      future: _grants,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('加载中…',
                style: TextStyle(fontSize: Tk.fzSm, color: Tk.subtle)),
          );
        }
        if (snap.hasError) {
          return Text(
              errorMessage(snap.error ?? '', '授权列表加载失败'),
              style: const TextStyle(fontSize: Tk.fzSm, color: Tk.red));
        }
        final grants = snap.data ?? const <ProjectGrantRow>[];
        if (grants.isEmpty) {
          return const Text('暂无额外授权 · 审批通过/文件夹邀请的授权会出现在这里',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.subtle));
        }
        return Column(
          children: [
            for (final g in grants)
              ListTile(
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key_outlined, size: 20),
                title: Text(
                    '${g.name ?? g.subjectId} · '
                    '${_objectLabel(g.objectType)}${g.objectName == null ? '' : '「${g.objectName}」'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: Tk.fzMd)),
                subtitle: Text(
                  '${g.level}${g.permanent ? ' · 长期' : g.expiresAt == null ? ' · 临时' : ' · 到期 ${g.expiresAt}'}',
                  style: const TextStyle(fontSize: Tk.fzXs, color: Tk.subtle),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '撤回授权',
                  onPressed: () => _revokeGrant(g),
                ),
              ),
          ],
        );
      },
    );
  }
}
