import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications 22.x iOS 必配(插件 README §「iOS setup —
    // General setup」与 example ios/Runner/AppDelegate.swift 同款):前台展示
    // (willPresentNotification)经 UNUserNotificationCenter delegate 转发到
    // 插件自带 delegate,缺这行前台/刚切后台(尚未完全 background)时通知
    // 不弹(用户反馈 #8「iOS 无系统级提示」根因之一)。FlutterAppDelegate
    // 本身实现 UNUserNotificationCenterDelegate 并转发给
    // addApplicationDelegate 注册的插件。
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
