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
/// app-polish-2 I3(#5 弹层太高难发现可取消):maxHeightFactor 0.9→0.85;
/// 把手拖拽关闭走守卫的能力沿用 D2 自制把手(遮罩点击仍不可关);关闭钮
/// 视觉放大在 sheet_scaffold 全局生效。
/// app-polish-3 E1/E2/D6:四个文本字段统一 AppTextField(去 isDense,修
/// 「高级」展开后浮起 label 上半截被裁);项目管理员改 UserPickerField 弹层
/// 形态(label 由字段承担);自制把手条抽至 widgets/handle_strip.dart。
/// app-polish-3 拆件(单文件 ≤300 行铁律):表单体抽至 new_project_form.dart
/// (NewProjectForm,状态仍在此持有经 props 下发),无权限兜底视图抽至
/// new_project_no_permit.dart;行为零变更。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/buttons.dart';
import '../../widgets/handle_strip.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/sheet_scaffold.dart';
import '../folders/folder_form_sheet.dart' show kProjectCodePattern;
import 'artist_account_field.dart';
import 'initial_grants_field.dart';
import 'new_project_form.dart';
import 'new_project_no_permit.dart';
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
      return NewProjectNoPermit(
          onClose: () => Navigator.of(context).pop(false));
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
          HandleStrip(onDismiss: _attemptClose),
          SheetScaffold(
            title: '新建项目',
            // I3 #5:0.9→0.85(弹层太高难发现可取消);把手/关闭钮守卫同 D2
            maxHeightFactor: 0.85,
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
                ? ArtistResultView(
                    username: created.artistAccount!.username,
                    name: created.artistAccount!.name,
                    password: created.artistAccount!.temporaryPassword,
                    onFinish: () => Navigator.of(context).pop(true),
                  )
                : NewProjectForm(props: _formProps(me)),
          ),
        ],
      ),
    );
  }

  /// 表单体入参组装:状态全部在此持有,子组件不读 session(props 下发,
  /// 回调上行 setState 也在此;codeValidator/艺人跟随判断均留在父级)。
  NewProjectFormProps _formProps(Me? me) {
    return NewProjectFormProps(
      formKey: _formKey,
      name: _name,
      code: _code,
      desc: _desc,
      bucket: _bucket,
      admin: _admin,
      onAdminChanged: (v) => setState(() => _admin = v),
      rows: _rows,
      onRowsChanged: (v) => setState(() => _rows = v),
      folderTemplateId: _folderTemplateId,
      onFolderTemplateChanged: (v) => setState(() => _folderTemplateId = v),
      artistGate: _artistGate,
      onArtistChanged: (v) => setState(() => _artist = v),
      onNameChanged: (_) => _projectNameManual = true,
      onArtistNameFollow: (v) {
        // 项目名未被手动编辑过时跟随艺人姓名(web F3-① 同款)
        if (!_projectNameManual) _name.text = v;
      },
      codeValidator: _codeError,
      showSelfAdminHint: _admin.any((u) => u.id == me?.id),
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
}
