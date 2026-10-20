/// MsApp — MaterialApp 装配:主题(§10 令牌)+ 命名路由 + Session 冷启动探活。
/// 路由仍为命名路由 + Navigator.push(不引 go_router)。
library;

import 'package:flutter/material.dart';

import 'core/session.dart';
import 'features/assets/assets_page.dart';
import 'features/auth/change_password_page.dart';
import 'features/auth/login_page.dart';
import 'features/baidu/bind_code_page.dart';
import 'features/folders/folders_page.dart';
import 'features/me/b0_download_poc_page.dart';
import 'features/shell/home_shell.dart';
import 'theme/app_theme.dart';

class MsApp extends StatefulWidget {
  const MsApp({super.key});

  @override
  State<MsApp> createState() => _MsAppState();
}

class _MsAppState extends State<MsApp> {
  @override
  void initState() {
    super.initState();
    // 冷启动探活(§4):命中即用;登录页监听 Session 呈现 探测中/不可达·重试
    session.probe();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '浣花视界',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      navigatorKey: session.navigatorKey,
      locale: const Locale('zh', 'CN'),
      onGenerateRoute: (s) {
        switch (s.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const LoginPage());
          case '/home':
            return MaterialPageRoute(builder: (_) => const HomeShell());
          case '/change-password':
            // arguments=true 强制流(must_change_password;无返回,成功进 HomeShell)
            final forced = (s.arguments as bool?) ?? false;
            return MaterialPageRoute(
                builder: (_) => ChangePasswordPage(forced: forced));
          case '/folders':
            final projectId = s.arguments as String;
            return MaterialPageRoute(
                builder: (_) => FoldersPage(projectId: projectId));
          case '/assets':
            final a = s.arguments as (String, String); // (folderId, folderName)
            return MaterialPageRoute(
                builder: (_) => AssetsPage(folderId: a.$1, folderName: a.$2));
          case '/baidu-bind':
            // B0① 百度绑定 oob 复制码流程(§8.10)
            return MaterialPageRoute(builder: (_) => const BindCodePage());
          case '/b0-download-poc':
            // B0② Android 落盘 PoC(入口仅 Android 显示)
            return MaterialPageRoute(
                builder: (_) => const B0DownloadPocPage());
        }
        return null;
      },
    );
  }
}
