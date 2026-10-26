/// 全局测试配置(storm-fix W1 #9):每条用例后清理缩略图管线/URL 缓存状态
/// (仅状态清理,防跨用例串扰;watchdog 正确性由「终态必取消 + testWidgets
/// 卸载树在不变量断言前触发全部 dispose→cancel」保证)。框架自测试文件目录
/// 向上扫描到本文件(最近者生效),test/** 全部用例共享。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/thumb_pipeline.dart';
import 'package:ms_app/core/thumbnail_cache.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  tearDown(() {
    thumbPipeline.reset();
    thumbnailCache.clear();
  });
  await testMain();
}
