/// NewProjectForm — 新建项目表单体(app-polish-3 自 new_project_sheet.dart
/// 拆分;2026-10 墨金重做):状态由 sheet 持有经 props 下发+回调上行。
/// 版式=分组标签(13/600/ink2)+ 字段/选择器 + 金色浅底说明卡;文本字段统一
/// AppTextField(isDense:false 修浮起 label 裁切)。
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/context_tk.dart';
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

  /// 已选 bucket 值(只读选择器恒有值,无需校验/controller)。
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

/// 新建项目表单体:名称/编码/描述/管理员/目录模板/初始权限/艺人/高级 bucket。
class NewProjectForm extends StatelessWidget {
  const NewProjectForm({super.key, required this.props});

  final NewProjectFormProps props;

  @override
  Widget build(BuildContext context) {
    final p = props;
    final tk = context.tk;
    return Form(
      key: p.formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            label: '项目名称',
            controller: p.name,
            hint: '2026 春季婚礼策划',
            validator: (v) => (v ?? '').trim().isEmpty ? '请输入项目名称' : null,
            onChanged: p.onNameChanged,
          ),
          const SizedBox(height: Tk.spaceLg),
          AppTextField(
            label: '项目编码(小写字母/数字/-)',
            controller: p.code,
            hint: 'wedding-2026-spring',
            validator: p.codeValidator,
          ),
          const SizedBox(height: Tk.spaceXs),
          Text(
            '提交后不可改;影响 MinIO 路径前缀',
            style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
          ),
          const SizedBox(height: Tk.spaceLg),
          AppTextField(label: '描述(可选)', controller: p.desc),
          const SizedBox(height: Tk.spaceLg),
          _FormGroup(
            label: '项目管理员',
            requiredMark: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UserPickerField(
                  value: p.admin,
                  multiple: false,
                  hint: '选一个项目管理员(默认自己)',
                  preset: mePreset(),
                  allowClear: false,
                  onChanged: p.onAdminChanged,
                ),
                if (p.showSelfAdminHint) ...[
                  const SizedBox(height: Tk.spaceXs),
                  Text(
                    '你本人将作为项目管理员',
                    style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
                  ),
                ],
              ],
            ),
          ),
          _FormGroup(
            label: '目录模板',
            hint: '创建项目时按模板生成目录树',
            child: FolderTemplateField(
              value: p.folderTemplateId,
              onChanged: p.onFolderTemplateChanged,
            ),
          ),
          _FormGroup(
            label: '初始权限',
            hint: '可选;创建后可继续调整',
            child: InitialGrantsField(
              value: p.rows,
              onChanged: p.onRowsChanged,
            ),
          ),
          if (p.artistGate)
            _FormGroup(
              label: '艺人账号',
              hint: '可选;两项都留空 = 仅创建项目',
              child: ArtistAccountFields(
                onChanged: p.onArtistChanged,
                onNameFollow: p.onArtistNameFollow,
              ),
            ),
          const SizedBox(height: Tk.spaceLg),
          // 高级折叠:bucket 对普通用户易困惑,收进折叠(web PR-3 同款)
          _AdvancedBucket(bucket: p.bucket, onTap: p.onBucketTap),
          const SizedBox(height: Tk.spaceMd),
          _Note(
            icon: Icons.info_outline,
            text: '创建后将自动合并组织默认权限模板；行内显式删除的角色也可能被合并回来。',
          ),
          const SizedBox(height: Tk.spaceSm),
        ],
      ),
    );
  }
}

/// 分组标签(13/600/ink2)+ 可选 hint + 子内容(组前 20 / 组后 8)。
class _FormGroup extends StatelessWidget {
  const _FormGroup({
    required this.label,
    required this.child,
    this.hint,
    this.requiredMark = false,
  });

  final String label;
  final Widget child;
  final String? hint;
  final bool requiredMark;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.only(bottom: Tk.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: Tk.fzMd,
                  fontWeight: FontWeight.w600,
                  color: tk.ink2,
                ),
              ),
              if (requiredMark) Text(' *', style: TextStyle(color: tk.danger)),
              if (hint != null) ...[
                const SizedBox(width: Tk.spaceSm),
                Expanded(
                  child: Text(
                    hint!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Tk.spaceSm),
          child,
        ],
      ),
    );
  }
}

/// 高级区:MinIO bucket 只读选择(统一 PickerField;不新增校验)。
class _AdvancedBucket extends StatelessWidget {
  const _AdvancedBucket({required this.bucket, required this.onTap});

  final String bucket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          '高级',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
        ),
        children: [
          PickerField(
            label: 'MinIO bucket(必填)',
            value: minioBucketLabel(bucket),
            onTap: onTap,
          ),
          const SizedBox(height: Tk.spaceXs),
          Text(
            '仅可选择已有存储桶;项目创建后不可修改',
            style: TextStyle(fontSize: Tk.fzXs, color: tk.ink3),
          ),
          const SizedBox(height: Tk.spaceSm),
        ],
      ),
    );
  }
}

/// 说明卡(金浅底 + 金字,§F13 表单语言;仅作提示不参与校验)。
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      padding: const EdgeInsets.all(Tk.spaceMd),
      decoration: BoxDecoration(
        color: tk.goldSoft,
        borderRadius: BorderRadius.circular(Tk.rSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: tk.goldInk),
          const SizedBox(width: Tk.spaceSm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: Tk.fzXs,
                height: 1.55,
                color: tk.goldInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
