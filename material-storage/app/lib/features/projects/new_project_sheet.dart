/// NewProjectSheet — 新建项目(B6 §8.5;web NewProjectModal 移动版):
/// 字段对齐 ProjectCreateIn 实况——名称/code(小写字母数字-,前端 pattern 同
/// 后端)/描述/项目管理员(必填,默认=创建者,UserPicker 单选)/minio_bucket
/// (必填默认 ms-dev,收进高级折叠;无「可见性」字段)/权限模板展开为
/// initial_grants 行(≤50,initial_grants_field.dart)/目录模板预填
/// (folder_template_field.dart)/艺人账号可选开通(artist_account_field.dart,
/// 闸门 is_artist_account_creator;停顿预检+一次性密码回显。总闸门 is_project_creator;成功 invalidate projects scope。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/pickers/user_picker.dart';
import '../folders/folder_form_sheet.dart' show kProjectCodePattern;
import 'artist_account_field.dart';
import 'folder_template_field.dart';
import 'initial_grants_field.dart';
import 'project_create_fail.dart';

/// 打开新建项目面板;返回是否创建成功。
Future<bool> showNewProjectSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _NewProjectSheet(),
  );
  return ok ?? false;
}

class _NewProjectSheet extends StatefulWidget {
  const _NewProjectSheet();

  @override
  State<_NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<_NewProjectSheet> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _desc = TextEditingController();
  final _bucket = TextEditingController(text: 'ms-dev'); // web 同款默认

  List<UserBrief> _admin = const [];
  var _rows = const <GrantRowData>[];
  String? _folderTemplateId;
  var _artist = (username: '', name: ''); // 两项全空 = 纯项目创建
  var _projectNameManual = false;

  /// 创建成功响应(带 artist_account 时一次性密码面板展示中,收口整个表单)。
  ProjectCreated? _created;

  /// 提交防重(P2-1):create await 期间禁用按钮并拦下重复提交。
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    // 默认项目管理员=创建者(web adminUserId=me.id 同款)
    _admin = mePreset();
  }

  @override
  void dispose() {
    for (final c in [_name, _code, _desc, _bucket]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _artistGate => session.me?.isArtistAccountCreator ?? false;

  String? _validate() {
    if (_name.text.trim().isEmpty) return '请输入项目名称';
    final code = _code.text.trim();
    if (code.length < 2 || code.length > 64) return '项目编码长度 2-64 个字符';
    if (!kProjectCodePattern.hasMatch(code)) {
      return '编码仅限小写字母/数字/-,以字母数字开头';
    }
    if (_admin.isEmpty) return '请指派项目管理员';
    if (_bucket.text.trim().isEmpty) return '请填写 MinIO bucket';
    if (_rows.length > kInitialGrantsMax) {
      return '初始权限最多 $kInitialGrantsMax 条,收到 ${_rows.length} 条';
    }
    for (final r in _rows) {
      if (r.roles.isEmpty) return '「${r.name}」行请至少勾选一个角色';
    }
    if (_artistGate && (_artist.username.isNotEmpty || _artist.name.isNotEmpty)) {
      if (_artist.username.isEmpty) return '已填写艺人姓名,登录名为必填';
      if (_artist.name.isEmpty) return '已填写登录名,艺人姓名为必填(不能全为空白)';
      final au = _artist.username;
      if (au.length < 2 || au.length > 64 || !kUsernamePattern.hasMatch(au)) {
        return '登录名仅限字母/数字与 . _ -,长度 2-64';
      }
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return; // P2-1 防连点(守卫须在首个 await 前同步生效)
    final err = _validate();
    if (err != null || _created != null) {
      if (err != null) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(err)));
      }
      return;
    }
    setState(() => _submitting = true);
    try {
      final p = await session.api!.projectsOps.create(
        code: _code.text.trim(),
        name: _name.text.trim(),
        minioBucket: _bucket.text.trim(),
        adminUserId: _admin.first.id,
        description: _desc.text.trim(),
        initialGrants: [
          for (final r in _rows)
            GrantEntry(kind: r.kind, id: r.id, roles: r.roles.toList()),
        ],
        folderTemplateId: _folderTemplateId,
        artistAccount: (_artist.username.isNotEmpty && _artist.name.isNotEmpty)
            ? (username: _artist.username, name: _artist.name)
            : null,
      );
      RefreshBus.I.invalidate('projects');
      if (!mounted) return;
      if (p.artistAccount != null) {
        // 密码只展示这一次(方案 F3-②):面板态收口整个表单
        setState(() => _created = p);
        return;
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          // P1-1:按 detail 形状归因(web 三分口径),勿把 code 冲突错归登录名
          content: Text('创建失败:${projectCreateFailCopy(e)}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('创建失败:$e')));
    } finally {
      if (mounted && _created == null) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = session.me;
    if (!(me?.isProjectCreator ?? false)) {
      // 无权限(直达兜底):web NewProjectModal 无权分支同文案口径
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 32, color: Tk.subtle),
            const SizedBox(height: 8),
            const Text('当前账号暂无新建项目权限',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
                '需要组织管理员,或加入已开启「允许组成员新建项目」的用户组。',
                style: TextStyle(fontSize: 12.5, color: Tk.subtle)),
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('关闭')),
          ]),
        ),
      );
    }
    if (_created != null) return _artistResultView();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('新建项目',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              _field('项目名称', _name,
                  hint: '2026 春季婚礼策划',
                  onChanged: (_) => _projectNameManual = true),
              const SizedBox(height: 10),
              _field('项目编码(小写字母/数字/-)', _code, hint: 'wedding-2026-spring'),
              const Text('提交后不可改;影响 MinIO 路径前缀',
                  style: TextStyle(fontSize: 11, color: Tk.subtle)),
              const SizedBox(height: 10),
              _field('描述(可选)', _desc),
              const SizedBox(height: 12),
              const Text('项目管理员(必填)',
                  style: TextStyle(fontSize: 12, color: Tk.muted)),
              UserPicker(
                value: _admin,
                multiple: false,
                preset: mePreset(),
                hint: '选一个项目管理员(默认自己)',
                onChanged: (v) => setState(() => _admin = v),
              ),
              if (_admin.any((u) => u.id == me?.id))
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('你本人将作为项目管理员',
                      style: TextStyle(fontSize: 11, color: Tk.subtle)),
                ),
              const SizedBox(height: 8),
              // 高级折叠:bucket 对普通用户易困惑,收进折叠(web PR-3 同款)
              Theme(
                data:
                    Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('高级', style: TextStyle(fontSize: 13.5)),
                  children: [
                    _field('MinIO bucket(必填)', _bucket, hint: 'PoC 统一 ms-dev'),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              if (_artistGate) ...[
                const SizedBox(height: 12),
                ArtistAccountFields(
                  onChanged: (v) => setState(() => _artist = v),
                  onNameFollow: (v) {
                    // 项目名未被手动编辑过时跟随艺人姓名(web F3-① 同款)
                    if (!_projectNameManual) _name.text = v;
                  },
                ),
              ],
              const SizedBox(height: 12),
              const Text('权限(可选)',
                  style: TextStyle(fontSize: 12, color: Tk.muted)),
              InitialGrantsField(
                  value: _rows,
                  onChanged: (v) => setState(() => _rows = v)),
              const SizedBox(height: 12),
              const Text('目录模板(可选)',
                  style: TextStyle(fontSize: 12, color: Tk.muted)),
              FolderTemplateField(
                value: _folderTemplateId,
                onChanged: (v) => setState(() => _folderTemplateId = v),
              ),
              const SizedBox(height: 16),
              // 默认权限模板直通说明(P2-4;web 提交区 Alert 同义):防「行内
              // 显式删除的角色被默认模板并回」无感知
              const Text(
                  '创建后将自动合并组织默认权限模板；行内显式删除的角色也可能被合并回来。',
                  style: TextStyle(fontSize: 11, color: Tk.subtle)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      (_created != null || _submitting) ? null : _submit,
                  child: const Text('创建'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 艺人账号一次性结果面板(创建成功带 artist_account 时整体替换表单)。
  Widget _artistResultView() {
    final a = _created!.artistAccount!;
    return ArtistResultView(
      username: a.username,
      name: a.name,
      password: a.temporaryPassword,
      onFinish: () => Navigator.of(context).pop(true),
    );
  }

  Widget _field(String label, TextEditingController c,
      {String? hint, void Function(String)? onChanged}) {
    return TextField(
      controller: c,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
