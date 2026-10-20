/// MsApp — MaterialApp 装配:主题(§10 令牌)+ 命名路由 + Session 冷启动探活。
/// 路由仍为命名路由 + Navigator.push(不引 go_router)。
library;

import 'package:flutter/material.dart';

import 'core/session.dart';
import 'features/assets/assets_page.dart';
import 'features/assets/trash_page.dart';
import 'features/auth/change_password_page.dart';
import 'features/auth/login_page.dart';
import 'features/baidu/bind_code_page.dart';
import 'features/folders/folders_page.dart';
import 'features/preview/preview_page.dart';
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
            // B3:附带项目名(上传任务 where 显示路径「项目/文件夹」用)
            final a = s.arguments as (String, String); // (projectId, projectName)
            return MaterialPageRoute(
                builder: (_) =>
                    FoldersPage(projectId: a.$1, projectName: a.$2));
          case '/assets':
            // B3:附带 where 显示路径(传输任务归属展示)
            final a = s.arguments as (String, String, String);
            return MaterialPageRoute(
                builder: (_) => AssetsPage(
                    folderId: a.$1, folderName: a.$2, where: a.$3));
          case '/trash':
            // B5:文件夹回收站(软删列表+恢复)
            final a = s.arguments as (String, String); // (folderId, folderName)
            return MaterialPageRoute(
                builder: (_) =>
                    TrashPage(folderId: a.$1, folderName: a.$2));
          case '/preview':
            // B2 §8.2 预览:列表序列+起点+单夹详情下载权
            final args = s.arguments as PreviewArgs;
            return MaterialPageRoute(
                builder: (_) => PreviewPage(args: args));
          case '/baidu-bind':
            // B0① 百度绑定 oob 复制码流程(§8.10)
            return MaterialPageRoute(builder: (_) => const BindCodePage());
        }
        return null;
      },
    );
  }
}
