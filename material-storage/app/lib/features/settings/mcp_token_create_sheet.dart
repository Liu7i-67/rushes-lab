/// MCP 访问令牌 创建表单弹层 + 创建成功一次性明文结果弹层(2026-11-19
/// settings-mcp-collapse F8,App 包A;对齐 web CreateTokenModal /
/// TokenCreatedModal)。
///
/// - 表单:名称(1~128)+ 有效期档位(30/90/180/365,默认 90;另有自定义
///   档 1~365 对齐 web InputNumber 能力);达活跃上限 5 禁用提交并给吊销引导
///   (后端仍 enforce 409,detail 中文透传);
/// - 结果:明文**唯一一次**展示(web 同语义)——弹层禁下拉/遮罩关闭,
///   只有「我已保存,关闭」一途;附整段可复制的 MCP 使用说明
///   ([buildMcpGuide],含明文,随弹层同生命周期,不落任何存储)。
/// P2 批:D15 风险文案 / 复制块 / 使用说明段收拢至 mcp_shared,
/// fmtIsoLong 归位 core/fmt.dart,本文件只保留表单与结果弹层编排。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart' show fmtIsoLong;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/sheet_scaffold.dart';
import 'mcp_shared.dart';

/// 每账号活跃令牌上限(web MAX_ACTIVE_TOKENS / 后端 enforce 同值)。
const int kMaxActiveTokens = 5;

/// 常用有效期档位(天);默认 90(web DEFAULT_EXPIRES_IN_DAYS 对齐)。
const List<int> kExpiryTiers = [30, 90, 180, 365];

const int _kCustomTier = 0; // AppSegmented 里代表「自定义」档

/// 打开创建表单弹层;创建成功 pop 回 [PatTokenCreated](明文只此一次),
/// 取消/关闭回 null。[activeCount] 供上限禁用展示(后端仍复核)。
Future<PatTokenCreated?> showMcpTokenCreateSheet(
  BuildContext context, {
  required int activeCount,
}) {
  return showAppSheet<PatTokenCreated>(
    context: context,
    title: '创建访问令牌',
    child: _CreateTokenSheet(activeCount: activeCount),
  );
}

class _CreateTokenSheet extends StatefulWidget {
  const _CreateTokenSheet({required this.activeCount});

  final int activeCount;

  @override
  State<_CreateTokenSheet> createState() => _CreateTokenSheetState();
}

class _CreateTokenSheetState extends State<_CreateTokenSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _daysCtrl = TextEditingController();

  var _tier = 90; // 默认 90 天
  var _custom = false;
  var _submitting = false;
  String? _error;

  bool get _full => widget.activeCount >= kMaxActiveTokens;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _daysCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_full || _submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final days = _custom ? int.tryParse(_daysCtrl.text.trim()) ?? 0 : _tier;
    if (days < 1 || days > 365) {
      setState(() => _error = '有效期须为 1~365 天');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created = await session.api!.tokens.createToken(
        name: _nameCtrl.text.trim(),
        expiresInDays: days,
      );
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = errorMessage(e, '创建令牌失败');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    // 创建请求进行中禁止关闭:关掉弹层会让「明文只回显一次」的响应无处展示
    return PopScope(
      canPop: !_submitting,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // D15 强制文案:创建页必须明示令牌的全权限与内网明文 http 风险
            // (统一正本 mcp_shared.kPatRiskNotice,与令牌页风险卡同源)
            Text(
              kPatRiskNotice,
              style: TextStyle(
                fontSize: Tk.fzMd,
                height: 1.6,
                color: tk.warn,
              ),
            ),
            if (_full) ...[
              const SizedBox(height: Tk.spaceMd),
              Text(
                '已达活跃令牌上限($kMaxActiveTokens 个),'
                '请先在列表中吊销不再使用的令牌,再创建新的。',
                style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.danger),
              ),
            ],
            const SizedBox(height: Tk.spaceLg),
            AppTextField(
              controller: _nameCtrl,
              label: '名称',
              hint: '我的 ZCode',
              maxLength: 128,
              enabled: !_submitting && !_full,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return '请填写令牌名称';
                if (s.length > 128) return '最多 128 个字符';
                return null;
              },
            ),
            const SizedBox(height: Tk.spaceSm),
            Text(
              '有效期(天)',
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
            ),
            const SizedBox(height: Tk.spaceSm),
            AppSegmented<int>(
              segments: [
                for (final d in kExpiryTiers) Segment(value: d, label: '$d'),
                const Segment(value: _kCustomTier, label: '自定义'),
              ],
              value: _custom ? _kCustomTier : _tier,
              onChanged: (v) {
                if (_submitting || _full) return;
                setState(() {
                  if (v == _kCustomTier) {
                    _custom = true;
                  } else {
                    _custom = false;
                    _tier = v;
                    _error = null;
                  }
                });
              },
            ),
            const SizedBox(height: Tk.spaceSm),
            if (_custom)
              AppTextField(
                controller: _daysCtrl,
                label: '自定义有效期(1~365 天)',
                keyboardType: TextInputType.number,
                enabled: !_submitting,
                validator: (v) {
                  final d = int.tryParse(v?.trim() ?? '');
                  if (d == null || d < 1 || d > 365) return '有效期须为 1~365 天';
                  return null;
                },
              )
            else
              Text(
                '默认 90 天;到期后令牌立即失效,也可随时吊销。',
                style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.ink3),
              ),
            if (_error != null) ...[
              const SizedBox(height: Tk.spaceSm),
              Text(
                _error!,
                style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.danger),
              ),
            ],
            const SizedBox(height: Tk.spaceLg),
            PrimaryXl(
              onPressed: (_full || _submitting) ? null : _submit,
              label: _submitting ? '创建中…' : '创建令牌',
            ),
            if (!_full) ...[
              const SizedBox(height: Tk.spaceSm),
              Text(
                '当前活跃令牌 ${widget.activeCount} / $kMaxActiveTokens',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 打开创建成功结果弹层(明文唯一一次展示;禁遮罩/下拉关闭)。
/// [endpoint] 为当前入口的 MCP 地址(origin + /mcp)。
Future<void> showMcpTokenCreatedSheet(
  BuildContext context, {
  required PatTokenCreated token,
  required String endpoint,
}) {
  return showAppSheet<void>(
    context: context,
    title: '令牌已创建',
    showClose: false,
    isDismissible: false,
    enableDrag: false,
    bottomActions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('我已保存,关闭'),
      ),
    ],
    child: _TokenCreatedSheet(token: token, endpoint: endpoint),
  );
}

class _TokenCreatedSheet extends StatelessWidget {
  const _TokenCreatedSheet({required this.token, required this.endpoint});

  final PatTokenCreated token;
  final String endpoint;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final guide = buildMcpGuide(endpoint: endpoint, token: token.token);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '这是令牌明文的唯一一次展示,关闭后无法再次查看。服务端只保存哈希,'
          '无法找回;请立即复制并妥善保管,使用说明亦含明文,勿粘贴到公开渠道。',
          style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.warn),
        ),
        const SizedBox(height: Tk.spaceMd),
        // 明文行:mono + 就地复制(P2-6 单行卡形态,视觉同原实现)
        MonoCopyBlock(
          inline: true,
          text: token.token,
          copyLabel: '复制',
          monoHeight: 1.4,
        ),
        const SizedBox(height: Tk.spaceLg),
        MonoCopyBlock(
          title: 'MCP 使用说明',
          text: guide,
          copyLabel: '复制说明',
          monoFontSize: 12,
          monoHeight: 1.7,
          blockPadding: const EdgeInsets.all(12),
        ),
        const SizedBox(height: Tk.spaceMd),
        Text(
          '名称:${token.name}\n'
          '前缀:${token.tokenPrefix}(列表中以此识别)\n'
          '有效期至:${fmtIsoLong(token.expiresAt)}',
          style: TextStyle(
            fontSize: Tk.fzMd,
            height: 1.8,
            color: tk.ink3,
          ),
        ),
      ],
    );
  }
}
