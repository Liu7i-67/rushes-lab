"""迁移前置邮箱体检(只读)— 邮箱账号方案 §4.4 / §9.3 第 1 步 / §9.5。

定位:§4.4 纯 SQL 预检的「便利脚本」形态 —— **代码同步后、`alembic upgrade`
前**在容器内跑(代码同步前也可用 §4.4 的 psql 命令,两者口径一致)。

执行(容器内,与 set_password 同款):

    docker exec ms-api python -m scripts.check_email_duplicates

硬约束(方案 §4.4/§12 第 25 条):
  - **纯 ``sqlalchemy.text()`` 显式列查询,不 import 任何 ORM 模型** ——
    代码同步后容器内已是新代码,任何 ``select(User)`` 都会 SELECT 新列
    (email_verified_at / session_version)而撞旧 schema(0020 同款失败面)。
    本文件因此连 ``app.db.tables`` 都不碰;mask_email 来自无 ORM 依赖的
    email_utils(方案 §5.1:它不得 import app.* 其它模块,反向成环被禁)。
  - 输出**脱敏值 + 用户 id**,完整邮箱不落终端(a***@example.com 形态)。
  - 只读:零 UPDATE/DELETE,失败即退出码非 0。

检查项(与 0021 迁移内重复检测 / §4.4 psql 逐条对齐,btrim 口径一致):
  1. 重复邮箱(lower(归一化) 分组 count>1)→ **阻断迁移**
  2. 跨列冲突(某账号 username == 另一账号 email)→ **阻断迁移**
  3. 统计:非空邮箱数 / 空串(含仅空白)数 / 大写数 / 疑似严格格式非法数
     (迁移会把空串归 NULL、大小写统一 lower,不阻断;疑似非法 §13.12
     不阻断迁移,但这类账号无法自助验证/找回,需管理员换绑)

阻断项有输出 → 退出码 1(runbook 第 1 步据此拦截,先清再迁移)。
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from typing import Any

from sqlalchemy import text

from app.db.session import get_sessionmaker
from app.services.email_utils import STRICT_EMAIL_RE, mask_email

# 与 0021 迁移 btrim(email, E' \t\n\r\f\v') 同一字符集(空格+制表+四类换行/换页);
# 用绑定参数而不是 E'' 字面量,免 SQL 方言转义分歧。
_TRIM_CHARS = " \t\n\r\f\v"

# 严格正则取自 email_utils.STRICT_EMAIL_RE(与 Pydantic 422 同一口径,单一事实源);
# PG 的 ~ / !~ 是 POSIX 正则,该 pattern 只含 ASCII 类与转义点/横线,可直接用。
_PATTERN = STRICT_EMAIL_RE.pattern

# ─── 阻断项(方案 §4.4 预检 #1/#2 的脚本形态)────────────────────────────────

_DUP_SQL = text("""
SELECT lower(btrim(email, :trim_chars)) AS norm_email,
       count(*) AS n,
       string_agg(id::text, ',' ORDER BY id) AS user_ids
FROM users
WHERE email IS NOT NULL AND btrim(email, :trim_chars) <> ''
GROUP BY 1
HAVING count(*) > 1
""")

_CROSS_SQL = text("""
SELECT a.id::text AS username_user_id, a.name AS username_user_name,
       b.id::text AS email_user_id, b.name AS email_user_name,
       a.username AS username_value, b.email AS email_value
FROM users a
JOIN users b
  ON lower(btrim(a.username, :trim_chars)) = lower(btrim(b.email, :trim_chars))
 AND a.id <> b.id
ORDER BY a.id, b.id
""")

# ─── 统计与明细(§4.4「同时统计:非空邮箱数、空串数、大写数、疑似格式非法数」)──

_STATS_SQL = text("""
SELECT count(*) FILTER (WHERE email IS NOT NULL
                          AND btrim(email, :trim_chars) <> '') AS non_empty,
       count(*) FILTER (WHERE email IS NOT NULL
                          AND btrim(email, :trim_chars) = '') AS empty_like,
       count(*) FILTER (WHERE email IS NOT NULL
                          AND btrim(email, :trim_chars) <> ''
                          AND btrim(email, :trim_chars)
                              <> lower(btrim(email, :trim_chars))) AS has_upper,
       count(*) FILTER (WHERE email IS NOT NULL
                          AND btrim(email, :trim_chars) <> ''
                          AND lower(btrim(email, :trim_chars)) !~ :pattern) AS suspect_invalid
FROM users
""")

_UPPER_SQL = text("""
SELECT id::text AS user_id, email
FROM users
WHERE email IS NOT NULL AND btrim(email, :trim_chars) <> ''
  AND btrim(email, :trim_chars) <> lower(btrim(email, :trim_chars))
ORDER BY id
""")

_INVALID_SQL = text("""
SELECT id::text AS user_id, email
FROM users
WHERE email IS NOT NULL AND btrim(email, :trim_chars) <> ''
  AND lower(btrim(email, :trim_chars)) !~ :pattern
ORDER BY id
""")

_EMPTY_SQL = text("""
SELECT id::text AS user_id
FROM users
WHERE email IS NOT NULL AND btrim(email, :trim_chars) = ''
ORDER BY id
""")


def _print_line(
    title: str, rows: list[dict[str, str]], *, blocking: bool
) -> None:
    """打印一组明细行(入参已是脱敏后的展示字符串,不再含完整邮箱)。"""
    tag = "阻断迁移" if blocking else "不阻断"
    print(f"\n[{title}] {len(rows)} 条({tag})")
    if not rows:
        print("  (无)")
        return
    for r in rows:
        print("  " + " | ".join(f"{k}={v}" for k, v in r.items()))


async def run_check(db: Any) -> int:
    """跑全部只读查询并输出报告;返回退出码(阻断项存在 → 1)。

    ``db`` 是 AsyncSession(text() 执行不需要 ORM);抽成参数只为单测注入替身。
    """
    params = {"trim_chars": _TRIM_CHARS, "pattern": _PATTERN}

    dup_rows = [
        {
            "email(脱敏)": mask_email(r.norm_email) or "?",
            "n": str(r.n),
            "user_ids": r.user_ids,
        }
        for r in (await db.execute(_DUP_SQL, params)).all()
    ]
    cross_rows = [
        {
            "username 归属": f"{r.username_user_id}({r.username_user_name})",
            "username(脱敏)": mask_email(r.username_value) or "?",
            "email 归属": f"{r.email_user_id}({r.email_user_name})",
            "email(脱敏)": mask_email(r.email_value) or "?",
        }
        for r in (await db.execute(_CROSS_SQL, params)).all()
    ]
    stats = (await db.execute(_STATS_SQL, params)).one()
    upper_rows = [
        {"user_id": r.user_id, "email(脱敏)": mask_email(r.email) or "?",
         "迁移动作": "→ lower(单向,原大小写不恢复)"}
        for r in (await db.execute(_UPPER_SQL, params)).all()
    ]
    invalid_rows = [
        {"user_id": r.user_id, "email(脱敏)": mask_email(r.email) or "?",
         "影响": "无法自助验证/找回,需管理员换绑"}
        for r in (await db.execute(_INVALID_SQL, params)).all()
    ]
    empty_ids = [r.user_id for r in (await db.execute(_EMPTY_SQL, params)).all()]

    print("=== 邮箱迁移前置体检(只读,text() 显式列,无 ORM)===")
    print(
        f"统计: 非空邮箱 {stats.non_empty} 条 | 空串/仅空白 {stats.empty_like} 条"
        f" | 大写 {stats.has_upper} 条 | 疑似严格格式非法 {stats.suspect_invalid} 条"
    )
    _print_line("重复邮箱(阻断项,先由管理员清空其一 PATCH email=null)", dup_rows, blocking=True)
    _print_line("跨列冲突 username==他人 email(阻断项,人工决定改哪一边)", cross_rows, blocking=True)
    _print_line("大写邮箱(迁移将统一 lower,不阻断)", upper_rows, blocking=False)
    _print_line("疑似严格格式非法(不阻断迁移;§13.12 需换绑)", invalid_rows, blocking=False)
    _print_line(
        "空串/仅空白(迁移将归 NULL,不阻断)",
        [{"user_id": i} for i in empty_ids],
        blocking=False,
    )

    blocking = bool(dup_rows or cross_rows)
    if blocking:
        print("\n结果: 存在阻断项 → 先按 §4.4 清理(管理员 PATCH email=null / 迁移前纯 SQL 改 username),再迁移。")
        return 1
    print("\n结果: 无阻断项,可继续上线顺序(§9.3 第 3 步 alembic upgrade head)。")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="迁移前置邮箱体检(只读;重复/跨列冲突阻断,脱敏输出)",
    )
    parser.parse_args(argv)  # 无旗标;保留 argparse 以提供 --help 与未知参数报错

    async def _run() -> int:
        sm = get_sessionmaker()
        async with sm() as session:
            return await run_check(session)

    return asyncio.run(_run())


if __name__ == "__main__":
    sys.exit(main())
