/// AlbumService.ensurePermission 单测(mobile-ux-polish-2 批 R2):
/// mock photo_manager 方法通道,断言显式请求口径
/// AndroidPermission(type: RequestType.all)(与选图器内部构造一致,
/// 系统弹窗一次含「照片和视频 / 音乐和音频」全部权限组);
/// 返回值契约不变(authorized=true,denied=false;P2 起拒绝态不抛)。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/services/album.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

void main() {
  // photo_manager 3.12 唯一方法通道(PMConstants.channelPrefix)
  const channel = MethodChannel('com.fluttercandies/photo_manager');

  Map<String, dynamic>? lastArgs;

  void mockPermissionChannel(WidgetTester tester, int resultCode) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestPermissionExtend') {
        lastArgs = (call.arguments as Map).cast<String, dynamic>();
      }
      return resultCode;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
  }

  testWidgets('显式 AndroidPermission(type: all):请求参数含照片+视频+音频',
      (tester) async {
    lastArgs = null;
    // PermissionState.authorized = index 3
    mockPermissionChannel(tester, PermissionState.authorized.index);

    final ok = await AlbumService.ensurePermission();
    expect(ok, isTrue, reason: '返回值契约不变:authorized 可进选图');
    expect(lastArgs, isNotNull);
    final android = lastArgs!['androidPermission'] as Map;
    expect(android['type'], RequestType.all.value,
        reason: 'R2:all=照片|视频|音频(与选图器内部口径一致,'
            '此前默认 common 缺音频,Android 13 未申明即 DENY)');
    expect(android['mediaLocation'], false,
        reason: '不申请照片定位元数据(与 picker 内部默认一致)');
  });

  testWidgets('denied → false(拒绝态不抛,由调用方接中文引导)', (tester) async {
    lastArgs = null;
    mockPermissionChannel(tester, PermissionState.denied.index);

    final ok = await AlbumService.ensurePermission();
    expect(ok, isFalse);
  });
}
