/// NewProjectForm — 新建项目表单体(app-polish-3 自 new_project_sheet.dart
/// 拆分):状态由 sheet 持有经 props 下发+回调上行;文案/结构逐字一致,勿改。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/pickers/picker_sheet.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/pickers/user_picker_field.dart';
import 'artist_account_field.dart';
import 'folder_template_field.dart';
import 'initial_grants_field.dart';
import 'minio_buckets.dart';

/// 表单体入参集(数据类承载,避免长位置参数表;状态归 sheet 所有)。
class NewProjectFormProps {
  const NewProjectFormProps({
    required this.formKey,
    required this.name,
    required this.code,
    required this.desc,
    required this.bucket,
    required this.onBucketTap,
    required this.admin,
    required this.onAdminChanged,
    required this.rows,
    required this.onRowsChanged,
    required this.folderTemplateId,
    required this.onFolderTemplateChanged,
    required this.artistGate,
    required this.onArtistChanged,
    required this.onNameChanged,
    required this.onArtistNameFollow,
    required this.codeValidator,
    this.showSelfAdminHint = false,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController name, code, desc;
  /// 已选 bucket 值(下拉恒有值,无需校验/controller)。
  final String bucket;
  final VoidCallback onBucketTap;
  final List<UserBrief> admin; // 项目管理员(单选,默认=创建者)
  final ValueChanged<List<UserBrief>> onAdminChanged;
  final List<GrantRowData> rows; // 初始权限行(initial_grants)
  final ValueChanged<List<GrantRowData>> onRowsChanged;
  final String? folderTemplateId; // 目录模板预填 id
  final ValueChanged<String?> onFolderTemplateChanged;
  final bool artistGate; // 艺人闸门 is_artist_account_creator(父级判定)
  /// 艺人两项输入上行(trim 后;sheet 据此决定是否带 artist_account)。
  final void Function(({String username, String name})) onArtistChanged;
  /// 项目名称输入(父级标记 _projectNameManual);艺人姓名跟随判断在父级。
  final ValueChanged<String> onNameChanged, onArtistNameFollow;
  /// codeValidator 实现在父级 _codeError;showSelfAdminHint=「你本人将作为
  /// 项目管理员」提示开关(admin 含本人,父级算好)。
  final FormFieldValidator<String>? codeValidator;
  final bool showSelfAdminHint;
}

/// 新建项目表单体:名称/编码/描述/管理员/高级/艺人/权限/目录模板。
class NewProjectForm extends StatelessWidget {
  const NewProjectForm({super.key, required this.props});

  final NewProjectFormProps props;

  @override
  Widget build(BuildContext context) {
    final p = props;
    return Form(
      key: p.formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            label: '项目名称',
            controller: p.name,
            hint: '2026 春季婚礼策划',
            validator: (v) =>
                (v ?? '').trim().isEmpty ? '请输入项目名称' : null,
            onChanged: p.onNameChanged,
          ),
          const SizedBox(height: Tk.spaceLg),
          AppTextField(
            label: '项目编码(小写字母/数字/-)',
            controller: p.code,
            hint: 'wedding-2026-spring',
            validator: p.codeValidator,
          ),
          const Text('提交后不可改;影响 MinIO 路径前缀',
              style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          const SizedBox(height: Tk.spaceLg),
          AppTextField(label: '描述(可选)', controller: p.desc),
          const SizedBox(height: Tk.spaceMd),
          UserPickerField(
            value: p.admin,
            multiple: false,
            label: '项目管理员(必填)',
            hint: '选一个项目管理员(默认自己)',
            preset: mePreset(),
            allowClear: false,
            onChanged: p.onAdminChanged,
          ),
          if (p.showSelfAdminHint)
            const Padding(
              padding: EdgeInsets.only(top: Tk.spaceXs),
              child: Text('你本人将作为项目管理员',
                  style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
            ),
          const SizedBox(height: Tk.spaceSm),
          // 高级折叠:bucket 对普通用户易困惑,收进折叠(web PR-3 同款)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('高级', style: TextStyle(fontSize: Tk.fzMd)),
              children: [
                // 第四批 A2:与 web 单选一致(原自由输入可写不存在桶名 →
                // 创建成功但首次上传 500 NoSuchBucket,bucket 又无 API 可改)
                PickerField(
                  label: 'MinIO bucket(必填)',
                  value: minioBucketLabel(p.bucket),
                  onTap: p.onBucketTap,
                ),
                const SizedBox(height: Tk.spaceSm),
              ],
            ),
          ),
          if (p.artistGate) ...[
            const SizedBox(height: Tk.spaceMd),
            ArtistAccountFields(
              onChanged: p.onArtistChanged,
              onNameFollow: p.onArtistNameFollow,
            ),
          ],
          const SizedBox(height: Tk.spaceMd),
          const Text('权限(可选)',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          InitialGrantsField(value: p.rows, onChanged: p.onRowsChanged),
          const SizedBox(height: Tk.spaceMd),
          const Text('目录模板(可选)',
              style: TextStyle(fontSize: Tk.fzSm, color: Tk.muted)),
          FolderTemplateField(
            value: p.folderTemplateId,
            onChanged: p.onFolderTemplateChanged,
          ),
          const SizedBox(height: Tk.spaceLg),
          // 默认权限模板直通说明(P2-4):防行内显式删除的角色被默认模板并回
          const Text(
              '创建后将自动合并组织默认权限模板；行内显式删除的角色也可能被合并回来。',
              style: TextStyle(fontSize: Tk.fzXs, color: Tk.subtle)),
          const SizedBox(height: Tk.spaceSm),
        ],
      ),
    );
  }
}
