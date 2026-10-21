/// FolderFormSheet — 新建子夹 / 项目根新建 / 重命名 三态表单(B6 §8.4):
/// 子夹仅名称(敏感夹只能直挂项目一级,后端 400);项目根新建带敏感开关;
/// 重命名预填现名。成功 invalidate folders scope;4xx detail 透传。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';

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

/// 文件夹名前端校验(后端 422 同口径:非空、拒首尾空白;段名字符集交后端
/// check_segment_name 透传)。
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
      text: widget.mode == FolderFormMode.rename ? widget.folder!.name : '');
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
          await session.api!.foldersOps
              .rename(widget.folder!.id, name: _name.text.trim());
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
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.mode == FolderFormMode.rename
        ? '「${widget.folder!.name}」'
        : widget.parentLabel == null
            ? ''
            : '「${widget.parentLabel}」下';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20,
            16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$_title$target',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '名称',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            // 敏感开关仅项目根新建出现(子夹恒普通:后端 400「sensitive folder
            // 只能直挂 project 一级」;重命名不改敏感性)
            if (widget.mode == FolderFormMode.createRoot) ...[
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('敏感文件夹', style: TextStyle(fontSize: 14.5)),
                subtitle: const Text('仅被邀请的成员可见;不可再建子夹、不可移动',
                    style: TextStyle(fontSize: 12)),
                value: _sensitive,
                onChanged: (v) => setState(() => _sensitive = v),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12.5)),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: Text(_submitting ? '保存中…' : '保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
