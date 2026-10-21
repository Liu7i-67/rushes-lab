/// NewProjectSheet — 新建项目(B6 §8.5;web NewProjectModal 移动版):
/// 字段对齐 ProjectCreateIn 实况——名称/code(小写字母数字-,前端 pattern 同
/// 后端)/描述/项目管理员(必填,默认=创建者,UserPicker 单选)/minio_bucket
/// (必填默认 ms-dev,收进高级折叠;maxLength 63 同后端限长;无「可见性」字段)/权限模板展开为
/// initial_grants 行(≤50,initial_grants_field.dart)/目录模板预填
/// (folder_template_field.dart)/艺人账号可选开通(artist_account_field.dart,
/// 闸门 is_artist_account_creator;停顿预检+一次性密码回显。总闸门 is_project_creator;成功 invalidate projects scope。
/// app-polish D2:Form+GlobalKey 校验,名称/code/bucket 内联 errorText(不再
/// 只靠提交时 SnackBar 报第一条),跨字段错误(admin/权限行/艺人)走
/// SheetScaffold errorText 位;「创建」PrimaryXl 吸底;关闭(自制把手下滑/
/// 关闭钮/返回键)有未保存输入→showAppConfirm「放弃编辑?」。框架拖拽关闭走
/// Navigator.pop 直呼(PopScope 拦不住)→ 改 isDismissible/enableDrag 双关+
/// 自制把手条,拖拽与关闭钮同走确认流。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/buttons.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/pickers/user_picker.dart';
import '../../widgets/sheet_scaffold.dart';
import '../folders/folder_form_sheet.dart' show kProjectCodePattern;
import 'artist_account_field.dart';
import 'folder_template_field.dart';
import 'initial_grants_field.dart';
import 'project_create_fail.dart';

/// 打开新建项目面板;返回是否创建成功(对外 API 不变)。
Future<bool> showNewProjectSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    // D2:关闭一律经 PopScope/自制把手守卫(未保存→确认),禁用遮罩点关与
    // 框架拖拽直关(直关绕过 PopScope,拦不住)
    showDragHandle: false,
    isDismissible: false,
    enableDrag: false,
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
  final _formKey = GlobalKey<FormState>();
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

  /// 跨字段错误(表单字段级错误走内联 errorText,D2):admin/权限行/艺人
  /// 与提交失败,渲染在 SheetScaffold errorText 位。
  String? _error;

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

  /// 字段级校验(name/code/bucket)交给 Form validator;此处只管跨字段项。
  String? _crossValidate() {
    if (_admin.isEmpty) return '请指派项目管理员';
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

  /// 是否有未保存输入(默认值/预置不算:bucket 默认 ms-dev、admin 默认自己)。
  bool get _hasUnsavedInput {
    final me = session.me;
    final adminChanged = _admin.length != 1 || _admin.first.id != me?.id;
    return _name.text.trim().isNotEmpty ||
        _code.text.trim().isNotEmpty ||
        _desc.text.trim().isNotEmpty ||
        _bucket.text.trim() != 'ms-dev' ||
        adminChanged ||
        _rows.isNotEmpty ||
        _folderTemplateId != null ||
        _artist.username.isNotEmpty ||
        _artist.name.isNotEmpty;
  }

  /// 关闭守卫:有未保存输入→确认层;确认/无输入才真正关闭(结果态直关)。
  Future<void> _attemptClose() async {
    if (!mounted) return;
    if (!_hasUnsavedInput) {
      Navigator.of(context).pop(false);
      return;
    }
    final ok = await showAppConfirm(
      context,
      title: '放弃编辑?',
      content: '表单有未保存的输入,关闭后将丢失。',
      confirmLabel: '放弃编辑',
      cancelLabel: '继续编辑',
      danger: false,
    );
    if (ok == true && mounted) Navigator.of(context).pop(false);
  }

  Future<void> _submit() async {
    if (_submitting) return; // P2-1 防连点(守卫须在首个 await 前同步生效)
    final fieldsOk = _formKey.currentState?.validate() ?? false;
    final cross = fieldsOk ? _crossValidate() : null;
    if (!fieldsOk || cross != null) {
      if (mounted) setState(() => _error = cross);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
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
        setState(() {
          _created = p;
          _submitting = false;
        });
        return;
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // P1-1:按 detail 形状归因(web 三分口径),勿把 code 冲突错归登录名
        _error = '创建失败:${projectCreateFailCopy(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '创建失败:${errorMessage(e, '请稍后重试')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = session.me;
    if (!(me?.isProjectCreator ?? false)) {
      // 无权限(直达兜底):web NewProjectModal 无权分支同文案口径
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HandleStrip(onDismiss: () => Navigator.of(context).pop(false)),
          SheetScaffold(
            title: '新建项目',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 32, color: Tk.subtle),
                const SizedBox(height: Tk.spaceSm),
                const Text('当前账号暂无新建项目权限',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: Tk.spaceXs),
                const Text(
                    '需要组织管理员,或加入已开启「允许组成员新建项目」的用户组。',
                    style: TextStyle(fontSize: Tk.fzSm, color: Tk.subtle)),
                const SizedBox(height: Tk.spaceLg),
                OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('关闭')),
              ],
            ),
          ),
        ],
      );
    }
    final created = _created;
    return PopScope(
      // 结果态(一次性密码已生成)不拦;表单态有未保存输入才弹确认
      canPop: created != null || !_hasUnsavedInput,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _attemptClose();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HandleStrip(onDismiss: _attemptClose),
          SheetScaffold(
            title: '新建项目',
            errorText: _error,
            bottomActions: created != null
                ? const <Widget>[]
                : <Widget>[
                    PrimaryXl(
                      onPressed: _submitting ? null : _submit,
                      label: _submitting ? '创建中…' : '创建',
                    ),
                  ],
            child: created != null
                ? _artistResultView(created)
                : _form(context, me),
          ),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, Me? me) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field('项目名称', _name,
              hint: '2026 春季婚礼策划',
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? '请输入项目名称' : null,
              onChanged: (_) => _projectNameManual = true),
          const SizedBox(height: Tk.spaceLg),
          _field('项目编码(小写字母/数字/-)', _code,
              hint: 'wedding-2026-spring', validator: _codeError),
          const Text('提交后不可改;影响 MinIO 路径前缀',
              style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          const SizedBox(height: Tk.spaceLg),
          _field('描述(可选)', _desc),
          const SizedBox(height: Tk.spaceMd),
          const Text('项目管理员(必填)',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          UserPicker(
            value: _admin,
            multiple: false,
            preset: mePreset(),
            hint: '选一个项目管理员(默认自己)',
            onChanged: (v) => setState(() => _admin = v),
          ),
          if (_admin.any((u) => u.id == me?.id))
            const Padding(
              padding: EdgeInsets.only(top: Tk.spaceXs),
              child: Text('你本人将作为项目管理员',
                  style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
            ),
          const SizedBox(height: Tk.spaceSm),
          // 高级折叠:bucket 对普通用户易困惑,收进折叠(web PR-3 同款)
          Theme(
            data:
                Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('高级', style: TextStyle(fontSize: Tk.fzMd)),
              children: [
                // 测试报告 P2-D2:后端 ProjectCreateIn.minio_bucket
                // max_length=63(api/app/models/__init__.py),前端同限——
                // maxLength 输入截断+计数器,校验器长度兜底
                _field('MinIO bucket(必填)', _bucket,
                    hint: 'PoC 统一 ms-dev',
                    maxLength: 63,
                    validator: (v) {
                      final b = (v ?? '').trim();
                      if (b.isEmpty) return '请填写 MinIO bucket';
                      if (b.length > 63) return 'bucket 最长 63 个字符';
                      return null;
                    }),
                const SizedBox(height: Tk.spaceSm),
              ],
            ),
          ),
          if (_artistGate) ...[
            const SizedBox(height: Tk.spaceMd),
            ArtistAccountFields(
              onChanged: (v) => setState(() => _artist = v),
              onNameFollow: (v) {
                // 项目名未被手动编辑过时跟随艺人姓名(web F3-① 同款)
                if (!_projectNameManual) _name.text = v;
              },
            ),
          ],
          const SizedBox(height: Tk.spaceMd),
          const Text('权限(可选)',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          InitialGrantsField(
              value: _rows,
              onChanged: (v) => setState(() => _rows = v)),
          const SizedBox(height: Tk.spaceMd),
          const Text('目录模板(可选)',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          FolderTemplateField(
            value: _folderTemplateId,
            onChanged: (v) => setState(() => _folderTemplateId = v),
          ),
          const SizedBox(height: Tk.spaceLg),
          // 默认权限模板直通说明(P2-4;web 提交区 Alert 同义):防「行内
          // 显式删除的角色被默认模板并回」无感知
          const Text(
              '创建后将自动合并组织默认权限模板；行内显式删除的角色也可能被合并回来。',
              style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          const SizedBox(height: Tk.spaceSm),
        ],
      ),
    );
  }

  /// 艺人账号一次性结果面板(创建成功带 artist_account 时整体替换表单)。
  Widget _artistResultView(ProjectCreated created) {
    final a = created.artistAccount!;
    return ArtistResultView(
      username: a.username,
      name: a.name,
      password: a.temporaryPassword,
      onFinish: () => Navigator.of(context).pop(true),
    );
  }

  String? _codeError(String? v) {
    final code = (v ?? '').trim();
    if (code.length < 2 || code.length > 64) return '项目编码长度 2-64 个字符';
    if (!kProjectCodePattern.hasMatch(code)) {
      return '编码仅限小写字母/数字/-,以字母数字开头';
    }
    return null;
  }

  Widget _field(String label, TextEditingController c,
      {String? hint,
      void Function(String)? onChanged,
      String? Function(String?)? validator,
      int? maxLength}) {
    return TextFormField(
      controller: c,
      onChanged: onChanged,
      validator: validator,
      maxLength: maxLength,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// 自制拖拽把手条(D2):框架 showDragHandle 的下滑关闭走 Navigator.pop 直呼,
/// PopScope 拦不住 → 自绘把手承接下滑手势,与关闭钮/返回键同走关闭守卫流。
/// 全宽 + 纵向 12 触控余量(测试自 sheet 顶 +24 下滑须命中);累计位移超阈值
/// 或下甩速度超阈值即触发。
class _HandleStrip extends StatefulWidget {
  const _HandleStrip({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  State<_HandleStrip> createState() => _HandleStripState();
}

class _HandleStripState extends State<_HandleStrip> {
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
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(Tk.rPill),
          ),
        ),
      ),
    );
  }
}
