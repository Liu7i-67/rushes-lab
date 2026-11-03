/// 「关于我们」页(feat/app-about-icp §2.2):二级页(带返回),居中展示
/// App logo → 名称「浣花视界」→ 版本号「版本 x.y.z+n」;底部居中工信部
/// 备案号行,点击外开备案核验站。纯静态页,无网络请求。
///
/// 注入缝(§7 公共契约):[AboutPage.localVersion]/[AboutPage.openUrl]
/// 供单测,null 走真实实现(appUpdate.currentVersion / launchUrl
/// externalApplication,后者照抄 login_page `_launchExternal` 模式)。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/update_flow.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/page_header.dart';

/// 工信部 App 备案号(§2.3 顶层常量导出,供测试与后续复用;双端同号,
/// 决策#1:若后续双平台各持独立号只改此处,不预留 Platform 分叉)。
const String kAppIcpNumber = '蜀ICP备2021008473号-4A';

/// 备案核验站(§2.3 顶层常量导出;备案号行点击外开)。
const String kIcpQueryUrl = 'https://beian.miit.gov.cn';

/// logo 视觉参数(§2.2:96×96,ClipRRect 圆角 20)。
const double _kLogoSize = 96;
const double _kLogoRadius = 20;

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.localVersion, this.openUrl});

  /// 版本来源注入(null = appUpdate.currentVersion;测试用,§7)。
  final Future<LocalAppVersion> Function()? localVersion;

  /// 外开链接注入(null = launchUrl externalApplication;测试用,§7)。
  final Future<bool> Function(String url)? openUrl;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  /// null = 读取中/读取失败 → 版本行显示 …;PackageInfo 通道异常静默,
  /// 容错口径参照 update_tile(不影响页面其余部分)。
  LocalAppVersion? _local;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final getter = widget.localVersion ?? appUpdate.currentVersion;
    try {
      final v = await getter();
      if (mounted) setState(() => _local = v);
    } catch (_) {
      // 读不到(如测试环境无插件通道)静默:版本行落 …,页面正常渲染
    }
  }

  Future<void> _openIcp() async {
    final open = widget.openUrl ?? _launchExternal;
    final ok = await open(kIcpQueryUrl);
    if (ok || !mounted) return;
    // 决策#3:外开失败落 SnackBar 轻提示,不打断页面
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('打开失败，请稍后重试')));
  }

  /// 外开系统浏览器:照抄 login_page `_launchExternal`(launchUrl +
  /// externalApplication + try/catch→bool),不在本页重构他人代码。
  Future<bool> _launchExternal(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final versionLabel = _local == null ? '…' : localVersionLabel(_local!);
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: '关于我们', back: true),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // §2.2:logo 96×96 圆角 20;Key 供测试定位
                ClipRRect(
                  key: const Key('about_logo'),
                  borderRadius: BorderRadius.circular(_kLogoRadius),
                  child: Image.asset(
                    'assets/logo.png',
                    width: _kLogoSize,
                    height: _kLogoSize,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: Tk.spaceLg),
                Text(
                  '浣花视界',
                  style: TextStyle(
                    fontSize: Tk.fzTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
                const SizedBox(height: Tk.spaceSm),
                Text(
                  '版本 $versionLabel',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                ),
              ],
            ),
          ),
          // §2.2:底部居中备案号行,点击外开核验站;Key 供测试定位与点击
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Tk.spaceLg),
              child: Center(
                child: InkWell(
                  key: const Key('about_icp'),
                  onTap: _openIcp,
                  borderRadius: BorderRadius.circular(Tk.rSm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tk.spacePage,
                      vertical: Tk.spaceMd,
                    ),
                    child: Text(
                      kAppIcpNumber,
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
