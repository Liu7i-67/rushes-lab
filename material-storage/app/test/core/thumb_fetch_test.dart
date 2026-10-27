/// ThumbFetch 组件级单测(storm-fix 测试功能点 T5 组件级):
/// fake HttpClientResponse body 永不产出 → watchdog 触发 subscription.cancel、
/// 下载 completer 以异常完成、名额回收(后续任务可进管线执行);
/// TTFB 期(响应头未到)取消 → req.abort 被调;200 正常交付;非 200 降级。
/// dart:io 真池行为不在单测范围(D7 分阶段语义以代码审查+真机验收兜底)。
///
/// 网络策略:fetchThumb 用 core/thumb_fetch.dart 的模块级静态 _thumbHttp,
/// 首次初始化须落在 HttpOverrides 桩 zone 内(此后整文件复用该桩,行为经
/// 模块级 _stubMode 切换),全程无真实 socket。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_fetch.dart';

import '../helpers/api_harness.dart';

// ── 桩 HTTP(仅本文件首颗 _thumbHttp 初始化时被 zone 捕获)───────────────────

enum _StubMode { ok, notFound, neverBody, hangTtfb }

_StubMode _stubMode = _StubMode.ok;

/// subscription.cancel 调用计数(body 期断流断言)。
int _subCancels = 0;

/// HttpClientRequest.abort 调用计数(TTFB 期取消断言)。
int _reqAborts = 0;

const _kBytes = [1, 2, 3, 7, 8, 9];

class _StubHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _lastUrl = url;
    return _StubRequest();
  }

  @override
  set connectionTimeout(Duration? _) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Uri? _lastUrl;

class _StubRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() {
    if (_stubMode == _StubMode.hangTtfb) {
      return Completer<HttpClientResponse>().future; // 永不到响应头
    }
    return Future<HttpClientResponse>.value(_StubResponse());
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _reqAborts++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubResponse implements HttpClientResponse {
  @override
  int get statusCode => _stubMode == _StubMode.notFound ? 404 : 200;

  @override
  Future<E> drain<E>([E? futureValue]) {
    return listen((_) {}).asFuture<E>().then((_) => futureValue as E);
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> element)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_stubMode == _StubMode.neverBody) {
      // body 永不产出:仅记录 cancel(T5 组件级断言点)
      return _HangingSubscription(() => _subCancels++);
    }
    return Stream<List<int>>.fromIterable([_kBytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HangingSubscription implements StreamSubscription<List<int>> {
  _HangingSubscription(this._onCancel);

  final void Function() _onCancel;

  @override
  Future<void> cancel() {
    _onCancel();
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ── 假 API(签名可计数;下载走桩 HttpClient)─────────────────────────────────

class _FetchAssetsApi extends FakeAssetsApi {
  _FetchAssetsApi(super.api);

  final thumbCalls = <String>[];

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
    thumbCalls.add(assetId);
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }
}

class _FetchMsApi extends FakeMsApi {
  late final _assets = _FetchAssetsApi(this);

  @override
  _FetchAssetsApi get assets => _assets;
}

void main() {
  setUp(() {
    _stubMode = _StubMode.ok;
    _subCancels = 0;
    _reqAborts = 0;
    _lastUrl = null;
  });

  testWidgets('200 正常路径:签名 1 次、用签名 URL 下载、字节交付', (tester) async {
    await HttpOverrides.runZoned(() async {
      final api = installFakeApi(_FetchMsApi()) as _FetchMsApi;
      addTearDown(() => session.api = null);
      _stubMode = _StubMode.ok;

      final h = fetchThumb('ok-a');
      await tester.pump();
      final bytes = await h.future;

      expect(api.assets.thumbCalls, ['ok-a'], reason: '签名恰 1 次');
      expect(
        _lastUrl?.toString(),
        'http://thumb.test/ok-a',
        reason: '用签名 URL 走静态 HttpClient',
      );
      expect(bytes, [1, 2, 3, 7, 8, 9], reason: '下载字节整包交付');
      expect(_subCancels, 0, reason: '正常完成不触发断流');
      await tester.pump(); // 无 pending timer(root 终态已取消 watchdog)
    }, createHttpClient: (_) => _StubHttpClient());
  });

  testWidgets('非 200(404)→ 下载失败上抛(drain 归还连接)', (tester) async {
    await HttpOverrides.runZoned(() async {
      installFakeApi(_FetchMsApi());
      addTearDown(() => session.api = null);
      _stubMode = _StubMode.notFound;

      final h = fetchThumb('nf-a');
      h.future.ignore(); // 失败异常监听兜底(expectLater 仍可后挂)
      await tester.pump();
      await expectLater(h.future, throwsA(isA<StateError>()));
      await tester.pump();
    }, createHttpClient: (_) => _StubHttpClient());
  });

  testWidgets('T5 组件级:body 永不产出 → subscription.cancel 被调、'
      '名额回收、后续任务可进管线执行', (tester) async {
    await HttpOverrides.runZoned(() async {
      final api = installFakeApi(_FetchMsApi()) as _FetchMsApi;
      addTearDown(() => session.api = null);
      _stubMode = _StubMode.neverBody;

      final h = fetchThumb('hang-a');
      h.future.ignore(); // 超时异常监听兜底(expectLater 仍可后挂)
      await tester.pump();
      expect(api.assets.thumbCalls, ['hang-a']);

      await tester.pump(const Duration(seconds: 20)); // watchdog
      await expectLater(h.future, throwsA(isA<TimeoutException>()));
      expect(_subCancels, 1, reason: '超时终止触发 body 期断流(subscription.cancel)');
      // 下载 completer 以异常完成:job await 处短路,异常被管线吞掉(无未处理错误)

      _stubMode = _StubMode.ok; // 名额已回收:后续任务立即执行
      final h2 = fetchThumb('next-b');
      await tester.pump();
      expect(api.assets.thumbCalls, ['hang-a', 'next-b']);
      expect(await h2.future, isNotNull, reason: '名额回收后新任务正常完成');
      await tester.pump();
    }, createHttpClient: (_) => _StubHttpClient());
  });

  testWidgets('TTFB 期(响应头未到)取消 → req.abort 被调、句柄 null 完成', (tester) async {
    await HttpOverrides.runZoned(() async {
      installFakeApi(_FetchMsApi());
      addTearDown(() => session.api = null);
      _stubMode = _StubMode.hangTtfb;

      final h = fetchThumb('ttfb-a');
      await tester.pump();
      Object? got = 'pending';
      h.future.then((v) => got = v, onError: (Object _) {});
      h.cancel();
      await tester.pump();
      expect(got, isNull, reason: '取消者句柄以 null 完成');
      expect(_reqAborts, 1, reason: '连接已建(getUrl 返回)未到响应头:abort 有效且被调');
      await tester.pump(); // 无 pending timer(watchdog 已同步取消)
    }, createHttpClient: (_) => _StubHttpClient());
  });
}
