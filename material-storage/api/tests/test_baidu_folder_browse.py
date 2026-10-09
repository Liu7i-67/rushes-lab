"""百度网盘目录浏览:文件可见(F1 全条目/F3 契约)— DB 容器集成层。

对应需求文档(唯一依据):docs/qdev/2026-10-09-baidu-folder-browse.md「测试功能点」7 条。
【集成】用例须跑容器栈(真实 PG/Redis/MinIO),门控与 tests/test_baidu_integration.py
同款:任一栈不可达 → 整模块 skip(fixture 按被装饰函数对象跨模块共享,见下)。
运行方式:`docker exec ms-api pytest tests/test_baidu_folder_browse.py -v`。

脚手架全量复用 tests/test_baidu_integration.py(world/client/enable_baidu/stack 等
fixture 与 _h/_touch_binding/random_fsid helper)。list mock 在既有 BaiduScript 上
派生(FolderBrowseScript):条目透传与按 folders_only 过滤的语义同父类及真实客户端
(folder=1 服务端过滤口径)——若端点回归成 folders_only=True,文件行会被 mock 如实
滤掉,两态断言即红(正是 F1 要拦的回归);另补两点:truncated 剧本化、list_dir
调用留痕((path, folders_only) 元组,缓存命中计数与请求口径断言用)。
seed 行按真实 xpan list 形态(调研脚本 scripts/task/baidu_file_list.py 实测口径):
目录行 isdir=1、path 即完整路径;文件行 isdir=0、path 是父目录(不是完整路径)、
名在 server_filename、size 为字节数。

测试函数 → 需求「测试功能点」映射(PM 验收对照):
  1. mock list 返回混合条目 → 端点两态条目:文件 is_dir=false/size_bytes 正确/
     path=父目录+server_filename 完整拼接;目录 is_dir=true/size_bytes=null;
     条目契约恰 path/name/is_dir/size_bytes 四字段;请求口径 folders_only=False
                                              → test_mixed_dir_entries_two_states_and_file_path_join
  2. 纯文件目录 → 非空列表(007「点开为空」场景直拍:1 png + 1 mp4 无子夹);
     根目录文件可见(007 报告原场景)且拼接不出现 //
                                              → test_files_only_dir_returns_nonempty
  3. 排序:目录在前文件在后、组内 name 升序(D4 后端排序,前端不排)
                                              → test_sort_dirs_first_files_after_name_order
  4. truncated=true 透传(条目不丢)           → test_truncated_passthrough
  5. 缓存:第二次同 path 走缓存(只打一次百度)且返回全条目(含文件行)
                                              → test_cache_hit_returns_full_entries
  6. 回归:400 path 校验(相对路径/过长)不变 + 绑定非 active → 409
     binding_inactive 不变(沿用既有用例断言口径)
                                              → test_regression_path_400_and_binding_inactive_409
  7. 前端:build+lint;(静态)文件行 selectable:false、loadData 不吞错 —— 前端
     车道承接(web/src 已由前端子智能体同步改造),不在本 API 测试文件范围。

对既有用例 tests/test_baidu_integration.py 的更新清单(该文件归后端子智能体本轮
维护,本文件不改它;以下为其本轮已落改动,列此交 PM 裁决核验):
  - 顶部 P1 清单表行改为「netdisk folders 目录+文件全条目(F1 两态/排序/文件路径
    拼接) + 缓存 + truncated + 非 active 409」。
  - test_binding_inactive_409_on_netdisk_folders 由「60s 缓存 + 409」扩为复合用例:
    混合条目 seeding、两态字段/文件路径拼接/组内排序断言、纯文件目录非空、缓存
    命中返回全条目(r2.json()==body)、truncated 透传(局部 _truncated 覆盖)、
    末段 409 binding_inactive 原样保留。
  → 复核结论:该文件已无 pin 旧「仅目录」语义的断言(folder=1 传参/仅目录响应均
    不再被断言),无进一步必改项;如 PM 认为该复合用例过宽,其 F1 相关段落可由
    本文件(已按功能点逐条拆分)替代,409/缓存段保留在原处即可。
"""
from __future__ import annotations

from typing import Any

import pytest

from app.services import baidu_client as baidu_client_module
from app.services.baidu_client import BaiduListResult
from tests import test_baidu_integration as it
from tests.test_baidu_integration import (  # 纯 helper 复用(与用例形参无同名冲突)
    BA,
    BaiduScript,
    World,
    _h,
    _touch_binding,
    random_fsid,
)

# fixture 再输出(赋值形态:from-import 直引会与用例签名同名形参撞 ruff F811,
# 赋值绑定不触发;解析按函数对象身份,与 test_baidu_integration 内定义即同一 fixture)
enable_baidu = it.enable_baidu
client = it.client
stack = it.stack
world = it.world


# ─── 目录浏览专用 list mock(既有 BaiduScript 派生)────────────────────────────
class FolderBrowseScript(BaiduScript):
    """在既有剧本上补目录浏览所需的两点:truncated 剧本化 + list_dir 调用留痕。

    条目透传/folders_only 过滤语义与父类一致(真实客户端 folder=1 为服务端过滤,
    mock 如实模拟,端点传参错了两态断言自然红)。
    """

    def __init__(self) -> None:
        super().__init__()
        self.truncated = False                       # list_dir 聚合未取尽(>max_pages)
        self.list_calls: list[tuple[str, bool]] = []  # (dir_path, folders_only) 留痕

    async def list_dir(self, access_token: str, dir_path: str, *,
                       folders_only: bool = False,
                       **_kwargs: Any) -> BaiduListResult:
        del access_token
        self.list_calls.append((dir_path, folders_only))
        if self.list_error:
            err, self.list_error = self.list_error, None
            raise err
        items = [dict(e, dir_path=None) for e in self.listing
                 if not folders_only or e.get("isdir")]
        return BaiduListResult(items=items, truncated=self.truncated)


@pytest.fixture
def mock_browse(monkeypatch: pytest.MonkeyPatch) -> FolderBrowseScript:
    """进程内替换 BaiduNetdiskClient 网盘交互(mock_baidu 同款挂法;剧本为目录浏览扩展版)。"""
    script = FolderBrowseScript()
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "stream_download", script.stream_download)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "filemetas_batch", script.filemetas_batch)
    monkeypatch.setattr(baidu_client_module.BaiduNetdiskClient, "list_dir", script.list_dir)
    return script


def _seed_dir_listing(script: FolderBrowseScript, dir_path: str, *,
                      dirs: list[str], files: list[tuple[str, int]]) -> None:
    """按真实 xpan list 行形态 seed 条目(字段口径见模块头);不预排序,seed 顺序
    保持调用方给定 —— 排序断言才有区分度。文件行 path=父目录(非完整路径)。"""
    rows: list[dict[str, Any]] = [
        {"fs_id": random_fsid(), "path": f"{dir_path.rstrip('/')}/{name}",
         "server_filename": name, "isdir": 1}
        for name in dirs
    ]
    rows += [
        {"fs_id": random_fsid(), "path": dir_path, "server_filename": name,
         "size": size, "isdir": 0}
        for name, size in files
    ]
    script.listing = rows


# ─── 功能点 1:混合条目 → 两态条目(path 拼接/size/is_dir 契约)──────────────────
async def test_mixed_dir_entries_two_states_and_file_path_join(
    world: World, client, enable_baidu, mock_browse, stack,
) -> None:
    """mock list 返回混合条目(目录+文件)→ 端点两态条目:文件 is_dir=false、
    size_bytes 正确、path=父目录+server_filename 完整拼接(后端拼,本改动最易踩的
    坑);目录 is_dir=true、size_bytes=null、path 即完整路径;条目契约恰四字段;
    请求口径为全量列举(folders_only=False,folder=0 等价)。【集成】需求点 1"""
    _seed_dir_listing(mock_browse, "/docs",
                      dirs=["乙目录", "甲目录"],      # seed 序刻意非名称序
                      files=[("b.png", 2048), ("a.mp4", 10)])
    r = await client.get(f"{BA}/netdisk/folders", params={"path": "/docs"},
                         headers=_h(world.member.id))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["truncated"] is False, "常规目录不置 truncated"
    by_name = {e["name"]: e for e in body["list"]}
    assert set(by_name) == {"乙目录", "甲目录", "a.mp4", "b.png"}, "两态条目全在(无丢失/无混叠)"

    # 目录态:path 即完整路径(现状口径)、size_bytes=None、is_dir=true
    d = by_name["甲目录"]
    assert set(d) == {"path", "name", "is_dir", "size_bytes"}, "条目契约(F3)恰四字段"
    assert d["path"] == "/docs/甲目录" and d["is_dir"] is True and d["size_bytes"] is None

    # 文件态:path=父目录+server_filename 完整拼接(mock 行 path 只是父目录 "/docs")
    f = by_name["a.mp4"]
    assert f["path"] == "/docs/a.mp4", "文件完整 path 必须后端拼(原 bug 直拍)"
    assert f["is_dir"] is False and f["size_bytes"] == 10
    assert by_name["b.png"]["size_bytes"] == 2048

    # 请求口径:必须向客户端要全量(folders_only=False);mock 如实过滤,folder=1
    # 回归会让文件行消失 → 上方两态断言红
    assert mock_browse.list_calls == [("/docs", False)]


# ─── 功能点 2:纯文件目录非空(007「点开为空」直拍)+ 根目录文件可见 ──────────────
async def test_files_only_dir_returns_nonempty(
    world: World, client, enable_baidu, mock_browse, stack,
) -> None:
    """纯文件目录(1 png + 1 mp4,无子夹,即 /灵机备份 实测场景)→ 非空列表:
    原实现 folders_only=True 下展开为空、用户感知「点不开」。根目录同理(007 报告
    原场景:根目录文件不显示),且根拼接不得出现 //。【集成】需求点 2"""
    _seed_dir_listing(mock_browse, "/灵机备份", dirs=[],
                      files=[("02.mp4", 6), ("01.png", 5)])
    r = await client.get(f"{BA}/netdisk/folders", params={"path": "/灵机备份"},
                         headers=_h(world.member.id))
    assert r.status_code == 200, r.text
    lst = r.json()["list"]
    assert lst, "纯文件目录必须非空(原「点开为空」场景直拍)"
    assert all(e["is_dir"] is False for e in lst), "该目录只有文件,不得混出目录态"
    assert [(e["name"], e["size_bytes"]) for e in lst] == [("01.png", 5), ("02.mp4", 6)]
    assert all(e["path"] == f"/灵机备份/{e['name']}" for e in lst), "文件 path=父目录+文件名"

    # 根目录(007 报告:根目录文件不可见)+ rstrip 拼接边界:path 不得是 "//根文件.mp4"
    _seed_dir_listing(mock_browse, "/", dirs=[], files=[("根文件.mp4", 7)])
    r_root = await client.get(f"{BA}/netdisk/folders", params={"path": "/"},
                              headers=_h(world.member.id))
    assert r_root.status_code == 200, r_root.text
    root_lst = r_root.json()["list"]
    assert root_lst, "根目录文件必须可见(007 报告原场景)"
    assert root_lst[0]["path"] == "/根文件.mp4", "根目录拼接不得出现 //"
    assert root_lst[0]["is_dir"] is False and root_lst[0]["size_bytes"] == 7


# ─── 功能点 3:排序 —— 目录前文件后、组内 name 升序(D4 后端排序)────────────────
async def test_sort_dirs_first_files_after_name_order(
    world: World, client, enable_baidu, mock_browse, stack,
) -> None:
    """seed 顺序刻意打乱(文件行在前、组内乱序)→ 响应严格为 目录组(名称升序)
    + 文件组(名称升序),组间不混排(前端不再排,后端序即展示序)。【集成】需求点 3"""
    _seed_dir_listing(mock_browse, "/mix",
                      dirs=["zeta-dir", "alpha-dir"],
                      files=[("m.mid", 1), ("b.txt", 2), ("a.txt", 3)])
    r = await client.get(f"{BA}/netdisk/folders", params={"path": "/mix"},
                         headers=_h(world.member.id))
    assert r.status_code == 200, r.text
    entries = r.json()["list"]
    assert [(e["name"], e["is_dir"]) for e in entries] == [
        ("alpha-dir", True), ("zeta-dir", True),
        ("a.txt", False), ("b.txt", False), ("m.mid", False),
    ], "目录前文件后、组内 name 升序(D4)"


# ─── 功能点 4:truncated 透传 ─────────────────────────────────────────────────────
async def test_truncated_passthrough(
    world: World, client, enable_baidu, mock_browse, stack,
) -> None:
    """list_dir 聚合未取尽(>max_pages)→ truncated=true 原样透传给前端(前端尾插
    「目录过大,仅显示部分内容」提示行),且已取条目两态俱全不丢。【集成】需求点 4"""
    mock_browse.truncated = True
    _seed_dir_listing(mock_browse, "/big",
                      dirs=["子目录"], files=[("video.mp4", 12345)])
    r = await client.get(f"{BA}/netdisk/folders", params={"path": "/big"},
                         headers=_h(world.member.id))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["truncated"] is True, "truncated 必须透传(不得被端点吞掉或改写)"
    assert [(e["name"], e["is_dir"]) for e in body["list"]] == [
        ("子目录", True), ("video.mp4", False),
    ], "truncated=True 时已取条目仍两态俱全"


# ─── 功能点 5:60s 缓存 —— 第二次同 path 走缓存且条目完整(含文件)────────────────
async def test_cache_hit_returns_full_entries(
    world: World, client, enable_baidu, mock_browse, stack,
) -> None:
    """同 (user, path) 60s 内二次请求 → 只打一次百度(list_dir 仅一次),且缓存命中
    返回全条目(部署后旧缓存自然过期,新缓存内容必须已是两态全条目)。【集成】需求点 5"""
    _seed_dir_listing(mock_browse, "/docs",
                      dirs=["子目录"], files=[("a.mp4", 10)])
    r1 = await client.get(f"{BA}/netdisk/folders", params={"path": "/docs"},
                          headers=_h(world.member.id))
    assert r1.status_code == 200, r1.text
    r2 = await client.get(f"{BA}/netdisk/folders", params={"path": "/docs"},
                          headers=_h(world.member.id))
    assert r2.status_code == 200
    assert [p for p, _flag in mock_browse.list_calls] == ["/docs"], "第二次必须走缓存(不触百度)"
    assert r2.json() == r1.json(), "缓存命中返回须与首刷一致"
    entries = r2.json()["list"]
    assert [(e["name"], e["is_dir"], e["path"], e["size_bytes"]) for e in entries] == [
        ("子目录", True, "/docs/子目录", None),
        ("a.mp4", False, "/docs/a.mp4", 10),
    ], "缓存内容必须是全条目(含文件行,非旧版仅目录空壳)"


# ─── 功能点 6:回归 —— 400 path 校验 + 非 active 409 binding_inactive 不变 ────────
async def test_regression_path_400_and_binding_inactive_409(
    world: World, client, enable_baidu, mock_browse, stack,
) -> None:
    """错误路径回归:相对路径/过长 path → 400(校验前置,不触网);绑定非 active
    → 409 binding_inactive(与创建/复活接口同码同义)。沿用既有 folders 用例断言
    口径。【集成】需求点 6"""
    r = await client.get(f"{BA}/netdisk/folders", params={"path": "relative/path"},
                         headers=_h(world.member.id))
    assert r.status_code == 400, r.text
    assert "以 / 开头" in r.text, "相对路径在路由层 400(勿留到枚举期)"
    r_long = await client.get(f"{BA}/netdisk/folders", params={"path": "/" + "a" * 1025},
                              headers=_h(world.member.id))
    assert r_long.status_code == 400 and "过长" in r_long.text, "path ≤1024 字符"

    # 非 active 绑定 → 409 binding_inactive(错误码 detail.code 口径不变)
    await _touch_binding(world.binding.id, status="unbound")
    r409 = await client.get(f"{BA}/netdisk/folders", params={"path": "/"},
                            headers=_h(world.member.id))
    assert r409.status_code == 409, r409.text
    assert "binding_inactive" in r409.text

    # 三次错误请求都不得触百度(400/409 校验均前置),也不产生可缓存的成功响应
    assert mock_browse.list_calls == []
