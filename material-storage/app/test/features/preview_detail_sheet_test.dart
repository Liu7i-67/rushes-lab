/// PreviewDetailSheet 单测(F9 测试功能点):详情面板打开/字段齐全/关闭。
/// P2-9:预览浮层固定暗色(D8)——浅色 App 主题下仍是 previewSurface 底 +
/// 暗色文字;顶部「更多操作」同口径。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/preview/preview_chrome.dart';
import 'package:ms_app/features/preview/preview_detail_sheet.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/theme/tokens.dart';

Asset _asset() => Asset(
  id: 'a1',
  filename: '封面 01.jpg',
  sizeBytes: 2048,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  userLabels: const ['精选', '封面'],
  notes: '拍摄于午后',
);

Asset _bare() => Asset(
  id: 'a2',
  filename: '未命名.bin',
  sizeBytes: 12,
  createdAt: '2026-10-21T08:00:00Z',
);

Future<void> _open(
  WidgetTester tester, {
  required Asset asset,
  String? where,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () =>
                  showPreviewDetailSheet(ctx, asset: asset, where: where),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开面板:标题「文件详情」与全部键值字段', (tester) async {
    await _open(tester, asset: _asset(), where: '项目A / 夹B');

    expect(find.text('文件详情'), findsOneWidget);
    for (final label in ['所属位置', '文件名', '类型', '大小', '上传时间', '标签', '备注']) {
      expect(find.text(label), findsOneWidget, reason: '字段:$label');
    }
    expect(find.text('项目A / 夹B'), findsOneWidget);
    expect(find.text('封面 01.jpg'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('2026-10-20'), findsOneWidget);
    expect(find.text('精选 · 封面'), findsOneWidget);
    expect(find.text('拍摄于午后'), findsOneWidget);
  });

  testWidgets('P2-9:浅色 App 主题下固定暗色(previewSurface 底 + 暗色文字)', (tester) async {
    await _open(tester, asset: _asset(), where: '项目A / 夹B');

    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(
      sheet.backgroundColor,
      Tk.previewSurface,
      reason: '预览详情浮层不被浅色主题拉回纸感浅底',
    );
    expect(
      tester.widget<Text>(find.text('文件详情')).style?.color,
      TkColors.dark.ink,
      reason: '标题取暗色 ink',
    );
    expect(
      tester.widget<Text>(find.text('所属位置')).style?.color,
      Tk.previewFg2,
      reason: '键列取暗色 previewFg2',
    );
    expect(
      tester.widget<Text>(find.text('项目A / 夹B')).style?.color,
      Tk.previewFg,
      reason: '值列取暗色 previewFg',
    );
  });

  testWidgets('P2-9:「更多操作」sheet 同为固定暗色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showPreviewMoreSheet(ctx, canRequest: true),
                child: const Text('more'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('more'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, Tk.previewSurface);
    expect(
      tester.widget<Text>(find.text('更多操作')).style?.color,
      TkColors.dark.ink,
      reason: '标题取暗色 ink',
    );
    expect(find.text('申请访问权限'), findsOneWidget);
    expect(find.text('文件详情'), findsOneWidget);
  });

  testWidgets('缺省值:位置/标签/备注为空时显示 —', (tester) async {
    await _open(tester, asset: _bare());

    expect(find.text('文件详情'), findsOneWidget);
    expect(
      find.text('—'),
      findsNWidgets(3),
      reason: 'where/labels/notes 各一处占位',
    );
    expect(find.text('未命名.bin'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget, reason: '无 contentType 归「文件」');
    expect(find.text('12 B'), findsOneWidget);
  });

  testWidgets('关闭:点右上关闭钮收起面板', (tester) async {
    await _open(tester, asset: _asset(), where: '项目A');

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('文件详情'), findsNothing);
  });
}
