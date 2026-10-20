/// ms_app — 医美素材库 iOS 端 MVP。
/// 验证链路:登录 → 项目/文件夹浏览 → 实况照片 livp 上传 / 下载存相册。
///
/// 后端入口:登录页 dev/prod 预设一键切换 + 自定义手填(外网/隧道口),
/// 选择持久化在 shared_preferences,重启保留;会话 cookie 持久化在
/// 应用支持目录(PersistCookieJar),重启免登录。
library;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/ms_api.dart';
import 'pages/assets_page.dart';
import 'pages/folders_page.dart';
import 'pages/login_page.dart';
import 'pages/projects_page.dart';
import 'services/app_log.dart';

/// 后端入口预设(2026-10-19 实测外网全通,手机直连):
///   dev  = http://47.108.196.211:8080(跳板机 → hh2 dev)
///   prod = https://bucket.taoxiplan.com(跳板机 TLS 终结,iOS 免 ATS 顾虑)
/// 以下地址走登录页「自定义」手填:
///   内网(工作室 WiFi 可达,更快):dev http://192.168.110.221:8090 /
///     prod http://192.168.110.221(:18080 外网 http 同样可达)
///   PC 调试隧道口:http://127.0.0.1:8200
const kDevEntry = 'http://47.108.196.211:8080';
const kProdEntry = 'https://bucket.taoxiplan.com';
const kApiPresets = <String, String>{'dev': kDevEntry, 'prod': kProdEntry};

/// 默认选中 dev;打包期可用 --dart-define=MS_API_BASE=... 覆盖默认值。
const kDefaultBaseUrl = String.fromEnvironment(
  'MS_API_BASE',
  defaultValue: kDevEntry,
);

/// 源码最后编辑时间(YYYY-MM-DD HH:mm),打包期注入、项目页标题展示,
/// 用于 TestFlight 肉眼确认装到的是最新构建(取 git HEAD 提交时刻):
///   flutter build ipa --release \
///     --dart-define=APP_BUILD_TIME="$(git log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M')"
/// 未注入(本地 flutter run/test)为空 → 标题不显示该段。
const kAppBuildStamp = String.fromEnvironment(
  'APP_BUILD_TIME',
  defaultValue: '',
);

const _kPrefKey = 'ms_api_base';

/// 手动切换的后端地址持久化(shared_preferences;插件通道不可用时回落默认)。
Future<String> loadBaseUrl() async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kPrefKey) ?? kDefaultBaseUrl;
  } catch (_) {
    return kDefaultBaseUrl;
  }
}

Future<void> saveBaseUrl(String url) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_kPrefKey, url);
  } catch (_) {/* 持久化失败不阻断登录 */}
}

MsApi? _api;
CookieJar? _persistentJar;

/// 全局单例(MVP 规模够用;换 baseUrl 时重建)。
MsApi apiOf(String baseUrl) => _api = MsApi(
      baseUrl: baseUrl,
      jar: _persistentJar ?? CookieJar(),
    );

Future<void> initPersistence() async {
  try {
    final dir = await getApplicationSupportDirectory();
    _persistentJar =
        PersistCookieJar(storage: FileStorage('${dir.path}/.cookies'));
  } catch (_) {
    // 测试环境无插件通道 → 内存 jar 兜底
  }
}

MsApi get api => _api!;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 全量日志先行(framework/zone 兜底在此挂上),UI 起来前的异常也不丢;
  // init 异步不阻塞启动,文件就绪前的日志走内存/控制台,就绪后逐条落盘
  AppLog.init();
  runApp(const MsApp());
}

class MsApp extends StatelessWidget {
  const MsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '浣花视界',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFC2410C),
        useMaterial3: true,
      ),
      locale: const Locale('zh', 'CN'),
      onGenerateRoute: (s) {
        switch (s.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const LoginPage());
          case '/projects':
            return MaterialPageRoute(builder: (_) => const ProjectsPage());
          case '/folders':
            final projectId = s.arguments as String;
            return MaterialPageRoute(
                builder: (_) => FoldersPage(projectId: projectId));
          case '/assets':
            final a = s.arguments as (String, String); // (folderId, folderName)
            return MaterialPageRoute(
                builder: (_) => AssetsPage(folderId: a.$1, folderName: a.$2));
        }
        return null;
      },
    );
  }
}
