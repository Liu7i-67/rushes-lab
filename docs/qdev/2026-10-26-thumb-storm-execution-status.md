# App 缩略图加载风暴修复 · 执行状态(2026-10-26 终局)

> 本文是 qdev 周期的执行记录(中途快照已收束为终局)。需求正本:`docs/qdev/2026-10-26-app-thumbnail-storm-fix.md`(15 轮盲审定稿)。
> worktree:`E:\qbb\github_not_me\rushes-lab-qplan-thumb-storm` · 分支 `feat/app-thumb-storm-fix`(基于 liuqi 8292700)· **未合并,合并与发版由用户拍板**。

## 一、流程终局

```
qplan 定稿(15 轮盲审,ea02c5e)
  └─ qdev 全周期闭环
       ├─ 包 A 后端        ✅ 320f63f(端点+T7-T10 测试)
       ├─ 包 B App core    ✅ 36acfcc(管线/签名闸/共享取字节/缓存批量)
       ├─ 包 C 拆分        ✅ 2dd7639(preview_image_view 纯迁移,D10 b-精简版)
       ├─ 同步化+假绿修复  ✅ 0fff6f0(ThumbDiskStore 全同步 IO+测试假绿修复)
       ├─ W4+W6 合并改造   ✅ a0f8bf6(预览数据源与放大行为,单一 revert 单元)
       ├─ PM 终验          ✅ analyze 0 亲验+全量 1088 测全绿+行数纪律核查
       ├─ 专职测试子智能体 ✅ P0=0/P1=0/P2×5(记档),补测探针 8 例全绿后已删
       ├─ 后端 T7-T10      ✅ hh2 dev 容器(ms-api-dev)5/5 通过,环境已还原(md5 对回部署态)
       └─ changelog 记账   ✅ 见 scripts/changelog.md 2026-10-26 节
```

实施中段包 C 子智能体曾因账号周/月限额中断(2026-10-28 14:24 重置),PM 曾接手编码;限额恢复后(10-26 当日)剩余测试改写按 qdev 并行派发 4 个子智能体完成。

## 二、提交清单

| 提交 | 内容 |
|---|---|
| `ea02c5e` | qplan 方案定稿(15 轮盲审 0P0/0P1 通过) |
| `0a1a8c6` | D10 落定:500 行纪律下 b-精简版(只拆 preview_image_view 一层) |
| `320f63f` | 包 A:`POST /assets/thumbnail-urls` 批量签名端点(1..100 单条 IN+missing 分流+每 20 条让出事件循环)+T7-T10 测试 329 行 |
| `36acfcc` | 包 B:thumb_pipeline(并发 6 闸/句柄取消/20s watchdog)/thumb_sign_gate(签名闸+abandonAwait)/thumb_fetch(共享取字节)/thumbnailCache 下沉+批量+4KB 权重/三端点 noErrorReport/宫格经 fetchThumb+T1-T6/T11②/T14 |
| `2dd7639` | 包 C 第一步:preview_image_view 拆出(纯迁移零行为) |
| `0fff6f0` | ThumbDiskStore 全同步 IO 化(fakeAsync 下异步文件 IO 挂死根治)+write/remove 去 _enqueue+debugHas+测试假绿修复 5 处 |
| `a0f8bf6` | W4(放大永不换原图,G2 链路删除)+W6(磁盘直读+fetchThumb 数据源+20s UI 总上限)合并改造+T12 六测试文件改写+T13 新建 12 例+T11① 宫格双挂点预热 |

## 三、测试终态

- `flutter analyze` **0 issues**;全量 `flutter test` **1088 全绿**(基线 1073+新增 15;带专职测试探针期间 1096 绿)。
- T12 改写终态:probe_p2 / preview_fallback_thumb / preview_polish / preview_polish2 / preview_media_fallback 全绿;T13 `preview_thumb_source_test.dart` 491 行 12 例全绿;T11① `assets_page_prewarm_test.dart` 绿。
- 后端 T7-T10 在 hh2 dev 容器(ms-api-dev)直调+ASGITransport 两级共 5/5 通过(容器内临时装 pytest/pytest-asyncio;**未部署、未重启 dev 服务**,assets.py 用后即还原,md5 回部署态 `a2669b3c…`)。

## 四、实施中发现并修复的关键问题(勿回退)

1. **子智能体写错目录(×2,前科)**:包 A/B 都曾把改动写进主仓,已搬回 worktree。后续派发 prompt 必须把 worktree 路径写成硬性第一条。
2. **B 包假绿(既有测试债)**:`thumbnail_image_disk_test.dart` 的 `inStubZone(body)` 返回的函数从未被调用——5 个用例空转假绿。已修复为 `})(tester)` 实调用。
3. **fakeAsync × 真实异步 IO = 挂死(本批最深的坑)**:库内任何 `await` 真实异步文件 IO 在 testWidgets 的 fakeAsync zone 内发起即挂死;`tester.runAsync` 推不动 fakeAsync 微任务。修复:`ThumbDiskStore.read/write/remove/clear` 全部同步 IO 化(百 KB 级同步亚毫秒,真机无感知)。
4. **`_enqueue` 互斥微任务链不可 flush**:write fire-and-forget 的 then 链在嵌套 zone 下不被 tester.pump flush。修复:write/remove 去互斥直接执行(同步段天然串行,跨代由代数校验兜底),`_mutex/_enqueue` 删除。
5. **测试配方定式(T12 落地版)**:磁盘预写优先(同步 IO 后库内 read 路径可同步走通);`HttpOverrides.runZoned` 假 HttpClient 仅同文件首个 fetch 前装桩(静态 `_thumbHttp` 首建绑 zone);轮询 `pump(50ms)×40`;`pumpAndSettle` 一轮不可达;用例内直接 `await ThumbDiskStore.write/read` 均安全。

## 五、专职测试结论(P0=0/P1=0,放行)

7 项重点补测(探针 8 例全绿后删除):①快滚 cancel 风暴名额幂等混流 5 轮 active 恒 ≤6;②签名闸 join 悬挂签名失败传播+不双减+失败不缓存毒;③宫格坏字节 remove(带代数)+切张 _tag 比对无误伤;④登出钩子顺序 pipeline→cache→disk 幂等;⑤livp 实况回切 Offstage 保活无回归;⑥搜索行/宫格/胶片条三入口统一经 fetchThumb;⑦双 20s 上限竞态先到者终态无 pending timer。回归审查(diff 范围/横切/inline/视频/PDF/下载/胶片条/沉浸/报错页 noErrorReport)全部通过。

## 六、遗留项(P2,不强修)

- P2-1 `preview_image_view.dart` 497/500 压线,再增即破纪律,后续拆层预案记档。
- P2-2 「磁盘代数捕获→read→跨代重捕获」逻辑在 thumbnail_image 与 preview_media 双写(~15 行),建议后续抽 ThumbDiskStore 侧小助手。
- P2-3 livp 实况播放中(player 分支)无「查看照片」回退按钮——B2 既有 UX 缺口(基线逐字同构),非本批回归。
- P2-4 `debugQueuedCount` 计原始队列长度(撤销任务实体留至下次 _pump 出队,行为正确仅计数语义)。
- P2-5 测试桩 HttpClient 夹具 4 文件私有副本,可下沉 test/helpers。
- 方案 §遗留项原样有效(D9 入口层核查/web 接入批量端点/优先级队列/容量评估/预热重试/CancelToken 改造/频控/悬挂上限/兼容层清理/cacheWidth)。

## 七、发布待办(用户拍板项)

- 合并 `feat/app-thumb-storm-fix` → liuqi(no-ff);发版按 D8:**API 先行部署,App 后发版**。
- 真机验收(方案验收标准 6 条:1000+ 文件快滚无超时风暴/预览磁盘秒出/放大恒缩略图/断网信号链/上传叠加/发布顺序)。
- liuqi push fork(待指令)。
