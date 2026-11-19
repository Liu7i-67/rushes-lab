/// mcp_shared — MCP 令牌两页(列表页 / 创建弹层)共享件(settings-mcp P2 批)。
///
/// - [kPatRiskNotice]:D15 强制风险文案统一正本(取两处原本中更完整的版本,
///   消除措辞小异);[kPatRiskHeadline] / [kPatRiskBody] 为令牌页风险卡
///   「标题行 + 正文段」派生拆分,避免同句渲染两遍;
/// - [MonoCopyBlock]:「标题(或说明)/ 复制 / mono 可选中文本」三段式组合件,
///   覆盖端点块、使用说明块与创建弹层明文行(inline)共四处重复实现;
/// - [buildMcpGuide] / [McpGuideCard]:MCP 使用说明整段文本与说明卡
///   (原 create_sheet / tokens_page 各自实现,P2-8 收拢于此)。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/copy_button.dart';

/// D15 强制风险文案统一正本(创建弹层整段展示;含「怀疑泄露立即吊销并改密」
/// 收尾句的完整版,两处不再各写一份)。
const String kPatRiskNotice =
    '令牌=账号级全权限凭证,等同你的密码;内网入口为明文 http,'
    '勿配置到不可信机器。持有令牌即可调用本账号可访问的全部 API'
    '(含上传与下载),请勿粘贴到聊天工具、截图或代码仓库。'
    '怀疑泄露时立即吊销,并修改密码(改密会自动吊销该账号全部令牌)。';

/// 风险卡标题行短句(正本首句,令牌页卡片加粗 warn 呈现)。
const String kPatRiskHeadline = '令牌=账号级全权限凭证,等同你的密码';

/// 风险卡正文段(正本去掉首句后的剩余部分;标题行已渲染
/// [kPatRiskHeadline],正文不再重复)。由 [kPatRiskNotice] 派生,单一正本。
final String kPatRiskBody = kPatRiskNotice.substring(
  kPatRiskHeadline.length + 1, // 跳过正本里衔接首句的「;」
);

/// MonoCopyBlock — 「标题(或说明)→ 复制 → mono 可选中文本卡」三段式组合件
/// (P2-6 抽公共:令牌页「MCP 端点」块/使用说明块与创建弹层明文行/使用说明
/// 块四处重复实现收拢;无状态,视觉与交互与原四处逐一零变化)。
///
/// 布局(段可缺省,自上而下):
/// - [title] 非 null:标题行(加粗)+ 行内 CopyButton(图标或带 [copyLabel]),
///   行距 spaceSm;
/// - title 为 null 且有 [hint]:先说明段,有 [copyLabel] 时按钮独立成段
///   (说明→按钮 spaceMd、按钮→文本卡 spaceSm);
/// - 末段恒为 mono SelectableText 卡(AppCard 包裹,[radius] 默认 rMd);
/// - [inline] = true:单行卡变体——文本与复制按钮同行(创建弹层明文行形态),
///   此时 title/hint 不可用(assert 防误用)。
class MonoCopyBlock extends StatelessWidget {
  const MonoCopyBlock({
    super.key,
    this.title,
    this.hint,
    required this.text,
    this.copyLabel,
    this.copyTooltip = '复制',
    this.inline = false,
    this.monoFontSize = 13,
    this.monoHeight,
    this.blockPadding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.radius,
  });

  /// 标题行文案(null = 无标题行;带 [copyLabel] 时按钮内联标题行尾)。
  final String? title;

  /// 标题/文本卡之间的说明段(null 省略)。
  final String? hint;

  /// 复制与展示共用的 mono 文本。
  final String text;

  /// CopyButton 文字标签(null = 图标按钮)。
  final String? copyLabel;
  final String copyTooltip;

  /// true = 单行卡(文本 + 按钮同行,创建弹层明文行形态)。
  final bool inline;
  final double monoFontSize;
  final double? monoHeight;
  final EdgeInsetsGeometry blockPadding;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: monoFontSize,
      height: monoHeight,
    );
    final copyButton = CopyButton(text: text, label: copyLabel, tooltip: copyTooltip);
    if (inline) {
      assert(
        title == null && hint == null,
        'inline 单行形态不支持 title / hint',
      );
      return AppCard(
        radius: radius,
        padding: blockPadding,
        child: Row(
          children: [
            Expanded(child: SelectableText(text, style: mono)),
            const SizedBox(width: Tk.spaceSm),
            copyButton,
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  title!,
                  style: TextStyle(
                    fontSize: Tk.fzRowTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
              ),
              copyButton,
            ],
          ),
          const SizedBox(height: Tk.spaceSm),
        ],
        if (hint != null) ...[
          Text(
            hint!,
            style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink2),
          ),
          SizedBox(
            height: title == null && copyLabel != null
                ? Tk.spaceMd
                : Tk.spaceSm,
          ),
        ],
        if (title == null && copyLabel != null) ...[
          copyButton,
          const SizedBox(height: Tk.spaceSm),
        ],
        AppCard(
          radius: radius,
          padding: blockPadding,
          child: SelectableText(text, style: mono),
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

/// D15 风险提示卡(P2-8 自 mcp_tokens_page._RiskCard 归位共享,视觉零变化):
/// 令牌管理页必须明示账号级全权限 + 内网明文 http 风险——
/// 标题行 [kPatRiskHeadline](加粗 warn)+ 正文段 [kPatRiskBody]。
class PatRiskCard extends StatelessWidget {
  const PatRiskCard({super.key});

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AppCard(
      padding: const EdgeInsets.all(Tk.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: tk.warn),
              const SizedBox(width: Tk.spaceSm),
              Expanded(
                child: Text(
                  kPatRiskHeadline,
                  style: TextStyle(
                    fontSize: Tk.fzRowTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.warn,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Tk.spaceSm),
          Text(
            kPatRiskBody,
            style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink2),
          ),
        ],
      ),
    );
  }
}

/// MCP 端点说明段卡(原 mcp_tokens_page._GuideCard,P2-8 归位共享):
/// 端点(origin + /mcp)行内复制 + 整段可复制使用说明(占位版;
/// 含明文的完整版在创建成功弹层给出)。
class McpGuideCard extends StatelessWidget {
  const McpGuideCard({super.key, required this.endpoint});

  final String endpoint;

  @override
  Widget build(BuildContext context) {
    final guide = buildMcpGuide(endpoint: endpoint);
    return AppCard(
      padding: const EdgeInsets.all(Tk.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoCopyBlock(
            title: 'MCP 端点',
            text: endpoint,
            copyTooltip: '复制端点',
            radius: Tk.rSm,
          ),
          const SizedBox(height: Tk.spaceMd),
          MonoCopyBlock(
            text: guide,
            copyLabel: '复制使用说明',
            hint: '在支持 MCP(HTTP 传输)的客户端按以下说明接入;身份=令牌'
                '所属用户本人,权限与网页登录一致。含令牌明文的完整配置说明会在'
                '创建令牌成功时给出,可整段复制。',
            monoFontSize: 12,
            monoHeight: 1.7,
            blockPadding: const EdgeInsets.all(12),
            radius: Tk.rSm,
          ),
        ],
      ),
    );
  }
}
