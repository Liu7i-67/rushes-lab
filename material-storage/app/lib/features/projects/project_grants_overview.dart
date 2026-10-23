/// ProjectGrantsOverview — 项目授权总览(B6 #138;自 project_members_sheet.dart
/// 拆分;2026-10 墨金重做):审批/邀请获得的 explicit/invited grant 列表 +
/// 四元组撤回。行=key 图标底 + 主体/对象 15.5 + 级别/有效期 13/ink3。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/toast.dart';

/// 打开项目成员管理面板时挂载;刷新经父侧 setState 重建驱动。
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
    final ok = await showAppConfirm(
      context,
      title: '撤回此授权?',
      content:
          '将撤回 ${g.name ?? g.subjectId} 对「$scope」的'
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
      toast(context, errorMessage(e, '撤回失败,请稍后重试'), tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return FutureBuilder<List<ProjectGrantRow>>(
      future: _grants,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Padding(
            padding: const EdgeInsets.all(Tk.spaceLg),
            child: Text(
              '加载中…',
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
            ),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(Tk.spaceLg),
            child: Text(
              errorMessage(snap.error ?? '', '授权列表加载失败'),
              style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
            ),
          );
        }
        final grants = snap.data ?? const <ProjectGrantRow>[];
        if (grants.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Tk.spaceLg),
            child: Text(
              '暂无额外授权 · 审批通过/文件夹邀请的授权会出现在这里',
              style: TextStyle(fontSize: Tk.fzMd, height: 1.55, color: tk.ink3),
            ),
          );
        }
        return Column(
          children: [
            for (final g in grants)
              ListTile(
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Tk.spaceSm,
                ),
                leading: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tk.surface3,
                    borderRadius: BorderRadius.circular(Tk.rSm),
                  ),
                  child: Icon(Icons.key_outlined, size: 17, color: tk.ink2),
                ),
                title: Text(
                  '${g.name ?? g.subjectId} · '
                  '${_objectLabel(g.objectType)}${g.objectName == null ? '' : '「${g.objectName}」'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: Tk.fzRowTitle, color: tk.ink),
                ),
                subtitle: Text(
                  '${g.level}${g.permanent
                      ? ' · 长期'
                      : g.expiresAt == null
                      ? ' · 临时'
                      : ' · 到期 ${g.expiresAt}'}',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, size: 18, color: tk.ink3),
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
