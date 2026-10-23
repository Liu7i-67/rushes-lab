/// toast 路由观察者(自 toast.dart 拆出,§5.6):路由 push/pop/replace 即销毁
/// 当前 toast。语义:页面切走,旧页提示对新页无意义;兼修 Overlay 条目跨
/// 路由存活、隐形盖住新页顶部(AppBar 返回键区)吞首击的缺陷。
/// app.dart 挂 MaterialApp.navigatorObservers;裸 MaterialApp 的单测环境
/// 未挂 observer 时不生效(同页 toast 行为零改动)。didPop 覆盖「toast 弹出
/// 后用户按返回」场景。
library;

import 'package:flutter/material.dart';

import 'toast.dart';

class ToastRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      dismissCurrentToast();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      dismissCurrentToast();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      dismissCurrentToast();
}
