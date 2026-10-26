/// P7/W6(mobile-ux-polish→app-thumbnail-storm-fix)预览降级单测。W6 改因:
/// 图片分支缩略图数据源统一为「磁盘优先 → miss 经共享取字节 fetchThumb(签名+
/// 静态 HttpClient 下字节)→ Image.memory」,原「thumbnailUrl 即回假地址 →
/// Image.network 直显」入口场景消失,对应断言改为 W6 磁盘命中口径;inline
/// 失败降级语义保留在——
/// - 图片无缩略图 → 原图 inline,失败维持原失败卡(文案不变),无提示条;
/// - 有缩略图但缩略图签名失败 → 失败卡(P2-6 两态文案);
/// - 视频 inline 失败有缩略图 → 同口径降级为静态帧渲染(不挂播放器)+ 提示。
/// (W4 用户拍板 D4:放大永不自动换原图,G2 升级链路整体删除——「放大签原图
/// 失败保持缩略图+提示」场景随之不复存在。)
/// 断言口径:widget 测试区网络图恒走 errorBuilder,故以「分支形态」
/// (InteractiveViewer=图片分支;无=失败卡/loading)与文案判定,不依赖像素。
/// API 内存假件(覆写 downloadLink 恒抛/thumbnailUrl 可编排),零真实网络 IO;
/// 缩略图字节经 ThumbDiskStore 临时目录夹具预写(dart:io 同步落盘,tearDown
/// 删除并重挂默认目录,T12 配方)。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 1×1 透明 PNG(经典字节,可真实解码;就地自建,勿 import 其他测试文件)。
final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// download-link 恒 403(仅查看权限口径)且记录调用,thumbnail-url 记录调用
/// (磁盘命中零签名断言)且可编排签名失败(thumbStaged,双失败用例)。
class _FallbackAssetsApi extends FakeAssetsApi {
  _FallbackAssetsApi(super.api);

  final linkCalls = <String>[];

  /// 单发签名调用记录(W6 磁盘命中应恒空)。
  final thumbCalls = <String>[];

  /// 非 null 且为 Exception → thumbnail-url 抛错(签名失败)。
  Object? thumbStaged;

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async {
    linkCalls.add(assetId);
    throw ApiException(403, '无下载权限(测试桩)');
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
    thumbCalls.add(assetId);
    if (thumbStaged is Exception) throw thumbStaged!;
    return (url: 'http://presigned/thumb/$assetId', expiresIn: 600);
  }
}

class _FallbackFakeMsApi extends FakeMsApi {
  late final _assets2 = _FallbackAssetsApi(this);

  @override
  _FallbackAssetsApi get assets => _assets2;
}

Asset _asset(
  String id, {
  required String filename,
  String? ct,
  Map<String, dynamic> tags = const {},
}) => Asset(
  id: id,
  filename: filename,
  sizeBytes: 4,
  contentType: ct,
  createdAt: '2026-10-20T10:00:00Z',
  tags: tags,
);

const _kThumbTag = {'thumbnail_key': 'k'};
const _kHint = '原图不可用(无下载权限或加载失败),当前为缩略图预览';

Future<void> _pump(
  WidgetTester tester,
  Asset asset, {
  _FallbackFakeMsApi? api,
}) async {
  installFakeApi(api ?? _FallbackFakeMsApi());
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PreviewMedia(asset: asset)),
    ),
  );
  await tester.pump(); // _load 微任务:磁盘直读/inline 失败回退链推进
  await tester.pump();
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pmf_thumb');
    ThumbDiskStore.I.debugAttachDirectory(dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    ThumbDiskStore.I.debugAttachDirectory(null);
  });

  /// W6 数据源跨多拍(磁盘 read 微任务 + setState):轮询推进假时钟直到图片
  /// 分支(InteractiveViewer)出现(T12 配方;pumpAndSettle 一轮不可达)。
  Future<void> pumpUntilImageBranch(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      if (find.byType(InteractiveViewer).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('W6:图片有缩略图 → 磁盘命中直出字节,不签原图无提示无失败卡', (tester) async {
    final api = _FallbackFakeMsApi();
    // 磁盘预写字节(同步 IO 直写):命中即零网络直出
    await ThumbDiskStore.I.write('p7-img', _kPng1x1);
    await _pump(
      tester,
      _asset('p7-img', filename: 'p7-img.jpg', tags: _kThumbTag),
      api: api,
    );
    await pumpUntilImageBranch(tester);
    expect(
      api.assets.linkCalls,
      isEmpty,
      reason: 'W6:有缩略图走磁盘直读,入口不签 download-link 原图',
    );
    expect(
      api.assets.thumbCalls,
      isEmpty,
      reason: '磁盘命中零签名(不发起 thumbnail-url)',
    );
    expect(find.text(_kHint), findsNothing, reason: '缩略图正常直显,无提示');
    expect(find.text('预览加载失败'), findsNothing, reason: '不落失败卡');
    // image 分支在渲染(InteractiveViewer 挂载)——磁盘字节直出生效
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
      findsOneWidget,
      reason: '缩略图以字节(Image.memory)直出,Image.network 路径退场',
    );
  });

  testWidgets('图片 inline 失败 + 无缩略图 → 维持原失败卡(文案不变,无提示条)', (tester) async {
    await _pump(tester, _asset('p7-nothumb', filename: 'p7-nothumb.jpg'));
    expect(find.text('预览加载失败'), findsOneWidget);
    expect(find.text(_kHint), findsNothing);
    expect(find.byType(InteractiveViewer), findsNothing, reason: '失败卡非图片分支');
  });

  testWidgets('P1-2 缺陷回归:缩略图签名失败(双失败)→ 失败卡,无「缩略图预览」提示条', (tester) async {
    final api = _FallbackFakeMsApi();
    api.assets.thumbStaged = ApiException(500, '签名失败(测试桩)');
    await _pump(
      tester,
      _asset('p7-both', filename: 'p7-both.jpg', tags: _kThumbTag),
      api: api,
    );
    // 改因(G2):入口不再签原图,本场景=缩略图签名失败;修复前 _thumbFallback
    // 在 await _loadThumb() 前置位,失败卡上叠提示条
    expect(find.text(_kHint), findsNothing, reason: '缩略图也不可用时不得显「当前为缩略图预览」提示');
    expect(
      find.byType(InteractiveViewer),
      findsNothing,
      reason: '降级未生效,呈现为失败卡而非图片分支',
    );
    expect(
      find.text('预览图还在生成,请稍后刷新重试'),
      findsOneWidget,
      reason: '缩略图签名失败 → 失败卡(P2-6 两态文案)',
    );
  });

  testWidgets('视频 inline 失败 + 有缩略图 → 磁盘命中静态帧降级 + 提示(不挂播放器)', (tester) async {
    final api = _FallbackFakeMsApi();
    // 磁盘预写字节:downloadLink 恒 403 → 回退 _loadThumb → 磁盘命中
    await ThumbDiskStore.I.write('p7-video', _kPng1x1);
    await _pump(
      tester,
      _asset(
        'p7-video',
        filename: 'p7-video.mp4',
        ct: 'video/mp4',
        tags: _kThumbTag,
      ),
      api: api,
    );
    await pumpUntilImageBranch(tester);
    expect(api.assets.linkCalls, [
      'p7-video',
    ], reason: '视频先试原图 inline(403)才回退缩略图');
    expect(api.assets.thumbCalls, isEmpty, reason: '回退走磁盘命中,零签名');
    expect(find.text(_kHint), findsOneWidget, reason: '回退缩略图,提示条一个');
    // 静态图分支渲染(image 分支);播放器未挂载(挂了会在无插件通道下异步报
    // 解码失败降级「视频解码失败」)
    expect(
      find.byType(InteractiveViewer),
      findsOneWidget,
      reason: '视频降级按静态图渲染,不挂播放器',
    );
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
      findsOneWidget,
      reason: '静态帧以磁盘字节(Image.memory)渲染',
    );
    expect(find.text('视频解码失败,建议下载后打开'), findsNothing);
  });
}
