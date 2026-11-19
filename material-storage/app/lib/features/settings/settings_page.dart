/// SettingsPage — App 设置页(2026-11-19 settings-mcp-collapse §3 F7/D3):
/// 「偏好」分组:SwitchListTile【默认收拢全部文件夹】——初值 getPrefs,
/// 切换乐观更新 PUT 成功对账、失败 Toast 报错并回弹;初值加载中开关禁用
/// 不误报。生效时机=下一次进入项目(App State 每次进入重建,D4,不做即时
/// 重排)。「MCP / AI 接入」分组:「访问令牌」入口行 → 命名路由 /mcp-tokens
/// (McpTokensPage 归并行包,路由注册见 app.dart)。
/// 现有「我的·外观」行与外观弹层原地保留不收编(D3);本页只承载本周期
/// 两项新内容。
/// P2 批:_toggle 挂请求代际守卫(旧 PUT 响应后到一律丢弃,不覆盖新值、
/// 不误弹 Toast);初值加载失败按 AppLog 惯例留痕(UI 仍静默禁用);
/// 分组容器复用 me_sections 的 MeGroup(删本页重复实现)。
/// 契约:导出 [SettingsPage](无参构造),app.dart 注册 /settings。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart' show errorMessage;
import '../../core/session.dart';
import '../me/me_sections.dart' show MeGroup;
import '../../services/app_log.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_row.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// null = 偏好初值加载中(开关禁用,避免拿默认值误报当前状态);
  /// 非 null = 当前值(乐观更新期间即新值)。
  bool? _collapsed;

  /// 单调递增请求代际(P2-3):await 后校验代际,旧 PUT 响应后到一律丢弃
  /// (成功不覆盖新值、失败不回弹不弹 Toast),只认最新一次切换。
  int _reqGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 初值加载:失败保持 null(开关禁用),偏好非关键数据不弹全局报错,
  /// 重进页面即重试;失败按 AppLog 留痕(P2-4,静默兜底语义不变)。
  Future<void> _load() async {
    try {
      final p = await session.api!.prefs.getPrefs();
      if (!mounted) return;
      setState(() => _collapsed = p.folderTreeDefaultCollapsed);
    } catch (e) {
      AppLog.error('settings', '偏好初值加载失败(开关维持禁用)', e);
    }
  }

  /// 切换:乐观更新本地值 → PUT;成功按服务端返回对账,失败回弹 + Toast。
  /// 代际守卫:仅最新一次切换可落态,慢到的旧响应被丢弃。
  Future<void> _toggle(bool v) async {
    final prev = _collapsed;
    final gen = ++_reqGen;
    setState(() => _collapsed = v);
    try {
      final p = await session.api!
          .prefs
          .updatePrefs(folderTreeDefaultCollapsed: v);
      if (!mounted || gen != _reqGen) return;
      setState(() => _collapsed = p.folderTreeDefaultCollapsed);
    } catch (e) {
      if (!mounted || gen != _reqGen) return;
      setState(() => _collapsed = prev);
      toast(context, errorMessage(e, '保存失败,请稍后重试'),
          tone: ToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: Tk.spaceXl),
        children: [
          const PageHeader(back: true, title: '设置'),
          MeGroup(title: '偏好', children: [
            SwitchListTile(
              value: _collapsed ?? false,
              // 初值未知时禁用,防「未加载完成即写入」的误报
              onChanged: _collapsed == null ? null : _toggle,
              title: Text(
                '默认收拢全部文件夹',
                style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
              ),
              subtitle: Text(
                '开启后,进入项目时文件夹树默认全部收拢,点击箭头逐层展开',
                style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
              ),
            ),
          ]),
          MeGroup(title: 'MCP / AI 接入', children: [
            AppRow(
              leading: const Icon(Icons.key_outlined),
              title: '访问令牌',
              subtitle: '创建与管理个人访问令牌(MCP / AI 客户端接入)',
              onTap: () => Navigator.of(context).pushNamed('/mcp-tokens'),
            ),
          ]),
        ],
      ),
    );
  }
}
