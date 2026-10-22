/// P7/G2(mobile-ux-polish→app-polish-2)预览降级单测。G2 改因:图片分支入口
/// 改为缩略图优先直显(不签原图),原「图片 inline 失败回退缩略图」入口场景
/// 消失,对应断言改为 G2 直显口径;inline 失败降级语义保留在——
/// - 图片无缩略图 → 原图 inline,失败维持原失败卡(文案不变),无提示条;
/// - 图片有缩略图但缩略图签名失败 → 失败卡(P2-6 两态文案);
/// - 视频 inline 失败有缩略图 → 同口径降级为静态帧渲染(不挂播放器)+ 提示。
/// (图片「放大 >1.5x 签原图失败保持缩略图+提示」见 preview_polish_test G2。)
/// 断言口径:widget 测试区网络图恒走 errorBuilder,故以「分支形态」
/// (InteractiveViewer=图片分支;无=失败卡/loading)与文案判定,不依赖像素。
/// API 内存假件(覆写 downloadLink 恒抛/thumbnailUrl 即回),零真实 IO。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// download-link 恒 403(仅查看权限口径)且记录调用,thumbnail-url 即回假签名
/// (thumbStaged 可编排签名失败,双失败用例)。
class _FallbackAssetsApi extends FakeAssetsApi {
  _FallbackAssetsApi(super.api);

  final linkCalls = <String>[];

  /// 非 null 且为 Exception → thumbnail-url 抛错(签名失败)。
  Object? thumbStaged;

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    linkCalls.add(assetId);
    throw ApiException(403, '无下载权限(测试桩)');
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
    if (thumbStaged is Exception) throw thumbStaged!;
    return (url: 'http://presigned/thumb/$assetId', expiresIn: 600);
  }
}

class _FallbackFakeMsApi extends FakeMsApi {
  late final _assets2 = _FallbackAssetsApi(this);

  @override
  _FallbackAssetsApi get assets => _assets2;
}

Asset _asset(String id,
    {required String filename,
    String? ct,
    Map<String, dynamic> tags = const {}}) =>
    Asset(
        id: id,
        filename: filename,
        sizeBytes: 4,
        contentType: ct,
        createdAt: '2026-10-20T10:00:00Z',
        tags: tags);

const _kThumbTag = {'thumbnail_key': 'k'};
const _kHint = '原图不可用(无下载权限或加载失败),当前为缩略图预览';

Future<void> _pump(WidgetTester tester, Asset asset,
    {_FallbackFakeMsApi? api}) async {
  installFakeApi(api ?? _FallbackFakeMsApi());
  addTearDown(() => session.api = null);
  await tester
      .pumpWidget(MaterialApp(home: Scaffold(body: PreviewMedia(asset: asset))));
  await tester.pump(); // _load 微任务:downloadLink 抛 → 回退 thumbnailUrl
  await tester.pump();
}

void main() {
  testWidgets('G2:图片有缩略图 → 进入直显缩略图,不签原图无提示无失败卡(原 P7 用例改因)',
      (tester) async {
    final api = _FallbackFakeMsApi();
    await _pump(tester, _asset('p7-img', filename: 'p7-img.jpg', tags: _kThumbTag),
        api: api);
    expect(api.assets.linkCalls, isEmpty,
        reason: 'G2:缩略图优先,入口不签 download-link 原图');
    expect(find.text(_kHint), findsNothing, reason: '缩略图正常直显,无提示');
    expect(find.text('预览加载失败'), findsNothing, reason: '不落失败卡');
    // image 分支在渲染(InteractiveViewer 挂载)——thumbnail-url 直显生效
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('图片 inline 失败 + 无缩略图 → 维持原失败卡(文案不变,无提示条)',
      (tester) async {
    await _pump(tester, _asset('p7-nothumb', filename: 'p7-nothumb.jpg'));
    expect(find.text('预览加载失败'), findsOneWidget);
    expect(find.text(_kHint), findsNothing);
    expect(find.byType(InteractiveViewer), findsNothing,
        reason: '失败卡非图片分支');
  });

  testWidgets('P1-2 缺陷回归:缩略图签名失败(双失败)→ 失败卡,无「缩略图预览」提示条',
      (tester) async {
    final api = _FallbackFakeMsApi();
    api.assets.thumbStaged = ApiException(500, '签名失败(测试桩)');
    await _pump(tester,
        _asset('p7-both', filename: 'p7-both.jpg', tags: _kThumbTag),
        api: api);
    // 改因(G2):入口不再签原图,本场景=缩略图签名失败;修复前 _thumbFallback
    // 在 await _loadThumb() 前置位,失败卡上叠提示条
    expect(find.text(_kHint), findsNothing,
        reason: '缩略图也不可用时不得显「当前为缩略图预览」提示');
    expect(find.byType(InteractiveViewer), findsNothing,
        reason: '降级未生效,呈现为失败卡而非图片分支');
    expect(find.text('预览图还在生成,请稍后刷新重试'), findsOneWidget,
        reason: '缩略图签名失败 → 失败卡(P2-6 两态文案)');
  });

  testWidgets('视频 inline 失败 + 有缩略图 → 静态帧降级 + 提示(不挂播放器)',
      (tester) async {
    await _pump(tester,
        _asset('p7-video', filename: 'p7-video.mp4', ct: 'video/mp4', tags: _kThumbTag));
    expect(find.text(_kHint), findsOneWidget);
    // 静态图分支渲染(image 分支);播放器未挂载(挂了会在无插件通道下异步报
    // 解码失败降级「视频解码失败」)
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: '视频降级按静态图渲染,不挂播放器');
    expect(find.text('视频解码失败,建议下载后打开'), findsNothing);
  });
}
