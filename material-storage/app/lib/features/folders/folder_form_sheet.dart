/// FolderFormSheet — 新建子夹 / 项目根新建 / 重命名 三态表单(B6 §8.4):
/// 子夹仅名称(敏感夹只能直挂项目一级,后端 400);项目根新建带敏感开关;
/// 重命名预填现名。成功 invalidate folders scope;4xx detail 透传。
/// F7:AppTextField + 令牌化开关;SheetScaffold 吸底金主按钮。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/sheet_scaffold.dart';

enum FolderFormMode { createChild, createRoot, rename }

/// 打开表单;返回是否成功提交(调用方据此刷新)。
Future<bool> showFolderFormSheet(
  BuildContext context, {
  required FolderFormMode mode,
  String? projectId,
  String? parentFolderId,
  Folder? folder, // rename 必传
  String? parentLabel, // 表单标题上下文(所属夹/项目名)
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FolderFormSheet(
      mode: mode,
      projectId: projectId,
      parentFolderId: parentFolderId,
      folder: folder,
      parentLabel: parentLabel,
    ),
  );
  return ok ?? false;
}

/// code 前端 pattern 同后端(ProjectCreateIn;新建项目表单共用)。
final RegExp kProjectCodePattern = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// 文件夹名前端校验(后端 422 同口径:非空、拒首尾空白)。
String? folderNameError(String? v) {
  final name = v?.trim() ?? '';
  if (name.isEmpty) return '请输入名称';
  if (name != (v ?? '')) return '名称首尾不能包含空白字符';
  return null;
}

class _FolderFormSheet extends StatefulWidget {
  const _FolderFormSheet({
    required this.mode,
    this.projectId,
    this.parentFolderId,
    this.folder,
    this.parentLabel,
  });

  final FolderFormMode mode;
  final String? projectId;
  final String? parentFolderId;
  final Folder? folder;
  final String? parentLabel;

  @override
  State<_FolderFormSheet> createState() => _FolderFormSheetState();
}

class _FolderFormSheetState extends State<_FolderFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.mode == FolderFormMode.rename ? widget.folder!.name : '',
  );
  bool _sensitive = false;
  var _submitting = false;
  String? _error;

  String get _title {
    switch (widget.mode) {
      case FolderFormMode.createChild:
        return '新建子文件夹';
      case FolderFormMode.createRoot:
        return '新建一级文件夹';
      case FolderFormMode.rename:
        return '重命名文件夹';
    }
  }

  Future<void> _submit() async {
    final err = folderNameError(_name.text);
    if (err != null || _submitting) {
      if (err != null) setState(() => _error = err);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      switch (widget.mode) {
        case FolderFormMode.createChild:
          await session.api!.foldersOps.create(
            projectId: widget.projectId!,
            parentFolderId: widget.parentFolderId,
            name: _name.text.trim(),
          );
        case FolderFormMode.createRoot:
          await session.api!.foldersOps.create(
            projectId: widget.projectId!,
            name: _name.text.trim(),
            isSensitive: _sensitive,
          );
        case FolderFormMode.rename:
          await session.api!.foldersOps.rename(
            widget.folder!.id,
            name: _name.text.trim(),
          );
      }
      RefreshBus.I.invalidate('folders');
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 409 同名/422 段名等 detail 透传
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '保存失败,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final target = widget.mode == FolderFormMode.rename
        ? '「${widget.folder!.name}」'
        : widget.parentLabel == null
        ? ''
        : '「${widget.parentLabel}」下';
    return SheetScaffold(
      title: '$_title$target',
      errorText: _error,
      bottomActions: [
        PrimaryXl(
          onPressed: _submitting ? null : _submit,
          label: _submitting ? '保存中…' : '保存',
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            controller: _name,
            label: '名称',
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          // 敏感开关仅项目根新建出现(子夹恒普通:后端 400;重命名不改敏感性)
          if (widget.mode == FolderFormMode.createRoot) ...[
            const SizedBox(height: Tk.spaceXs),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '敏感文件夹',
                style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
              ),
              subtitle: Text(
                '仅被邀请的成员可见;不可再建子夹、不可移动',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
              value: _sensitive,
              onChanged: (v) => setState(() => _sensitive = v),
            ),
          ],
        ],
      ),
    );
  }
}
