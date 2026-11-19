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
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/buttons.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/sheet_scaffold.dart';

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
            Text(
              '令牌=账号级全权限凭证,等同你的密码;内网入口为明文 http,'
              '勿配置到不可信机器。持有令牌即可调用本账号可访问的全部 API'
              '(含上传与下载),请勿粘贴到聊天工具、截图或代码仓库。',
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
        // 明文行:mono + 就地复制
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  token.token,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              CopyButton(text: token.token, label: '复制'),
            ],
          ),
        ),
        const SizedBox(height: Tk.spaceLg),
        Row(
          children: [
            Expanded(
              child: Text(
                'MCP 使用说明',
                style: TextStyle(
                  fontSize: Tk.fzRowTitle,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                ),
              ),
            ),
            CopyButton(text: guide, label: '复制说明'),
          ],
        ),
        const SizedBox(height: Tk.spaceSm),
        AppCard(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            guide,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.7,
            ),
          ),
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

/// MCP 使用说明整段文本(信息要素对齐 web TokenCreatedModal.buildMcpGuide)。
/// [token] 传实际明文(创建成功弹层);null = 占位版(令牌页接入说明段用,
/// 提示先创建令牌再替换占位)。包含明文时调用方须保证随展示即弃、不落存储。
String buildMcpGuide({required String endpoint, String? token}) {
  final t = token ?? '<你的访问令牌>';
  final origin = endpoint.replaceAll(RegExp(r'/mcp$'), '');
  final buf = StringBuffer()
    ..writeln('【素材库 MCP 配置】')
    ..writeln('MCP 地址:$endpoint')
    ..writeln('认证头:Authorization: Bearer $t')
    ..writeln('传输:Streamable HTTP(单副本;服务重启后客户端需重新 initialize)');
  if (token == null) {
    buf.writeln('认证头中的 <你的访问令牌> 请替换为在「MCP 访问令牌」页'
        '创建的令牌明文(仅创建成功时展示一次)。');
  }
  buf
    ..writeln()
    ..writeln('【客户端配置示例(支持 HTTP MCP 的客户端;字段名以客户端文档为准)】')
    ..writeln('{')
    ..writeln('  "mcpServers": {')
    ..writeln('    "material-storage": {')
    ..writeln('      "type": "http",')
    ..writeln('      "url": "$endpoint",')
    ..writeln('      "headers": {')
    ..writeln('        "Authorization": "Bearer $t"')
    ..writeln('      }')
    ..writeln('    }')
    ..writeln('  }')
    ..writeln('}')
    ..writeln()
    ..writeln('【给 AI 的使用提示】')
    ..writeln('你是素材库(Material Storage)助手,已通过上面的 MCP 地址与令牌接入;'
        '身份=令牌所属用户本人,权限与网页登录一致。')
    ..writeln('挑素材主路径:先 search_assets 搜索,再 get_thumbnail 看缩略图'
        '(先 size="small" 看构图,需要细节再 size="large")。')
    ..writeln('下载:get_download_url 返回 15 分钟有效的直链,'
        '请由客户端自行 HTTP GET 取字节,勿反复续签。')
    ..writeln('上传:create_upload → 客户端 PUT 直传(URL 15 分钟内有效,'
        'ETag 取自 PUT 响应头)→ complete_upload;单文件 ≤5GiB,'
        '同文件夹同名会 409。')
    ..writeln('complete_upload 超时后先 search_assets / list_files 确认资产'
        '是否已入库,再决定重试或 abort_upload。');
  if (token != null) {
    buf
      ..writeln()
      ..writeln('【自检(可选)】')
      ..write('curl -H "Authorization: Bearer $t" $origin/api/v1/auth/me');
  }
  return buf.toString();
}

/// ISO → 'YYYY-MM-DD HH:mm'(本地时区;令牌有效期展示用,带年份)。
String fmtIsoLong(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return iso;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
