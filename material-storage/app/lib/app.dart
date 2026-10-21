/// MsApp — MaterialApp 装配:主题(§10 令牌)+ 命名路由 + Session 冷启动探活。
/// 路由仍为命名路由 + Navigator.push(不引 go_router)。
library;

import 'package:flutter/material.dart';

import 'core/session.dart';
import 'features/admin/admin_audit_page.dart';
import 'features/admin/admin_baidu_tasks_page.dart';
import 'features/admin/admin_folder_templates_page.dart';
import 'features/admin/admin_grant_templates_page.dart';
import 'features/admin/admin_groups_page.dart';
import 'features/admin/admin_home.dart';
import 'features/admin/admin_users_page.dart';
import 'features/assets/assets_page.dart';
import 'features/assets/trash_page.dart';
import 'features/auth/change_password_page.dart';
import 'features/approvals/approvals_page.dart';
import 'features/auth/login_page.dart';
import 'features/baidu/bind_code_page.dart';
import 'features/notifications/notifications_page.dart';
import 'features/folders/folders_page.dart';
import 'features/preview/preview_page.dart';
import 'features/permissions/my_permissions_page.dart';
import 'features/projects/deleted_projects_page.dart';
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
            // B3:附带项目名(上传任务 where 显示路径「项目/文件夹」用);
            // B6:附带 my_roles(「新建一级文件夹」闸门=admin/uploader)
            final a = s.arguments as (String, String, List<String>);
            return MaterialPageRoute(
                builder: (_) => FoldersPage(
                    projectId: a.$1, projectName: a.$2, myRoles: a.$3));
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
          case '/approvals':
            // B7:审批中心(scope=all&pending / scope=self 双段)
            return MaterialPageRoute(builder: (_) => const ApprovalsPage());
          case '/notifications':
            // B7:通知中心(kind 白名单跳转)
            return MaterialPageRoute(builder: (_) => const NotificationsPage());
          case '/my-permissions':
            // B7:我的权限(项目角色 + 已批准临时授权)
            return MaterialPageRoute(builder: (_) => const MyPermissionsPage());
          case '/deleted-projects':
            // B6:已删除项目回收站(列表+恢复;入口闸门 is_project_deleter)
            return MaterialPageRoute(
                builder: (_) => const DeletedProjectsPage());
          case '/preview':
            // B2 §8.2 预览:列表序列+起点+单夹详情下载权
            final args = s.arguments as PreviewArgs;
            return MaterialPageRoute(
                builder: (_) => PreviewPage(args: args));
          case '/baidu-bind':
            // B0① 百度绑定 oob 复制码流程(§8.10)
            return MaterialPageRoute(builder: (_) => const BindCodePage());
          case '/admin':
            // B8:管理后台入口页(页内深链兜底二次闸 is_system_admin)
            return MaterialPageRoute(builder: (_) => const AdminHomePage());
          case '/admin/users':
            return MaterialPageRoute(builder: (_) => const AdminUsersPage());
          case '/admin/groups':
            return MaterialPageRoute(builder: (_) => const AdminGroupsPage());
          case '/admin/audit':
            return MaterialPageRoute(builder: (_) => const AdminAuditPage());
          case '/admin/grant-templates':
            return MaterialPageRoute(
                builder: (_) => const AdminGrantTemplatesPage());
          case '/admin/folder-templates':
            // 目录模板例外闸门(持 flag 非 admin 直达;页内 403 提示兜底)
            return MaterialPageRoute(
                builder: (_) => const AdminFolderTemplatesPage());
          case '/admin/baidu-tasks':
            return MaterialPageRoute(
                builder: (_) => const AdminBaiduTasksPage());
        }
        return null;
      },
    );
  }
}
