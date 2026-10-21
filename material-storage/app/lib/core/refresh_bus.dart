/// RefreshBus — 通用列表失效机制(B2 数据新鲜度 §8.1)。
///
/// 写操作(上传/删除/移动/打标/审批…)成功后 `invalidate(scope)`;挂着对应 scope
/// 的页面收到回调后自行 reload——解决 IndexedStack 常驻页(项目 tab)与常驻态
/// 列表挂陈旧数据的问题。scope 命名约定:`projects` / `folders` / `assets:<folderId>`。
///
/// 当前订阅现状(B9 P2-3 修后如实注):`projects` / `folders` / `baidu-tasks`
/// 三 scope 有订阅方(项目 tab 常驻 + folders 子树计数重拉 + 网盘备份页任务
/// 列表刷新);`assets:<folderId>` 现仅失效无订阅方——宫格页进出即整拉,不挂
/// 常驻监听,scope 属预留(B4 批量操作点亮时消费)。纯回调注册表,无框架
/// 依赖,可单测。
library;

import 'dart:ui' show VoidCallback;

class RefreshBus {
  RefreshBus();

  /// 全局单例(页面经此挂监听;测试可自建实例隔离)。
  static final RefreshBus I = RefreshBus();

  final _listeners = <String, Set<VoidCallback>>{};

  void invalidate(String scope) {
    final set = _listeners[scope];
    if (set == null) return;
    for (final cb in set.toList()) {
      cb();
    }
  }

  void addListener(String scope, VoidCallback cb) {
    _listeners.putIfAbsent(scope, () => <VoidCallback>{}).add(cb);
  }

  void removeListener(String scope, VoidCallback cb) {
    _listeners[scope]?.remove(cb);
  }
}
