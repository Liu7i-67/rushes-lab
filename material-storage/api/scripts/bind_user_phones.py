r"""存量用户手机号批量绑定脚本(手机绑定/短信找回密码方案 §9.4 / §4.3;B5 包)。

执行(api 容器内,默认 dry-run;--apply 必须显式搭配 --yes 才实跑):
  docker exec ms-api python -m scripts.bind_user_phones                       # dry-run 核对
  docker exec ms-api python -m scripts.bind_user_phones --apply --yes         # 实跑(幂等,可重跑)
  docker exec ms-api python -m scripts.bind_user_phones --apply --yes \
      --csv /tmp/pairs.csv        # 冲突人工裁决 / 补充指定(先 docker cp 进容器)

扫描口径(§9.4 逐句):
  - 只认 username(email 形态如 13800138000@139.com 不自动绑:邮箱本地部分归一化
    会引入跨账号折叠歧义,确有需要走 --csv 人工指定)
  - username 先做 D5 归一化(与绑定端点共用 app/services/phone_verification.normalize_phone:
    strip 空格/连字符/点号 → 去 +86/86 前缀)再匹配 ^1[3-9]\d{9}$,命中 → 候选
    phone(写入归一化值);归一化不过 → 该用户 skip 不自动绑
  - 已有 phone 的用户跳过(幂等);is_active 不做过滤(方案未要求)

冲突检测(全部进冲突名单跳过,绝不写库;§4.3):
  a. 归一化折叠:同一归一化手机号对应多个 username(13800138000 与 138-0013-8000
     都是合法 username)→ 全部候选进名单,人工裁决后 --csv 指定归属二跑
  b. 候选号已被其他用户占用(DB 里已有别的用户 phone=该号)
  c. --csv 双给:同一用户重复出现 / 同一 phone 指给多个用户
  d. --csv 二跑对「占用冲突」同样拒绝并输出名单(绝不覆盖 uq_users_phone 唯一
     约束,须先人工解除原绑定)

--csv:每行 `identifier,phone`(# 注释与空行忽略);identifier 支持
username/email/name/UUID,匹配口径同 set_password.py(username → email(含 @)
→ name → UUID,多行命中按歧义拒);phone 同样走 normalize_phone 后写入。

实跑逐条:UPDATE users.phone + 审计 phone_bound(details: actor="cli"、
source="backfill"、old_masked(原 phone 或 None)/new_masked),照 set_password.py
的独立 session 模式 —— 数据 commit 与审计分 session,audit.write 自带 commit
(仓内约定)。执行序(§9.4):dev dry-run 核对 → dev apply → prod dry-run 核对
→ prod apply;冲突名单人工裁决后 --csv 二跑。
"""

from __future__ import annotations

import argparse
import asyncio
import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import get_sessionmaker
from app.db.tables import User
from app.services.audit import AuditService
from app.services.phone_verification import InvalidPhone, mask_phone, normalize_phone


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="存量用户手机号批量绑定(默认 dry-run)")
    parser.add_argument("--apply", action="store_true", help="实际写库(默认 dry-run 只报告)")
    parser.add_argument(
        "--csv", metavar="PAIRS_CSV", help="人工指定对文件,每行 identifier,phone(# 注释与空行忽略)"
    )
    parser.add_argument(
        "--yes", action="store_true", help="--apply 的显式确认(docker exec / nohup 非交互必带)"
    )
    return parser.parse_args()


def parse_csv(path: str) -> list[tuple[str, str]]:
    """解析 --csv 文件:每行 identifier,phone;空行与 # 注释忽略;格式错误 fail-fast。"""
    pairs: list[tuple[str, str]] = []
    with open(path, encoding="utf-8-sig") as fh:
        for lineno, line in enumerate(fh, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = [p.strip() for p in stripped.split(",")]
            if len(parts) != 2 or not parts[0] or not parts[1]:
                raise SystemExit(f"--csv 第 {lineno} 行格式错误(期望 identifier,phone):{stripped!r}")
            pairs.append((parts[0], parts[1]))
    return pairs


async def find_user_unique(db: AsyncSession, identifier: str) -> tuple[User | None, str | None]:
    """set_password.find_user 同优先级(username → email(含 @)→ name → UUID)。

    与 set_password 的差异:命中多条/找不到不抛 SystemExit,而是返回错误说明交
    上层进 --csv 解析失败名单(批量场景不因单条 identifier 中断整批)。
    """
    try:
        uid = uuid.UUID(identifier)
        user = await db.get(User, uid)
        if user is not None:
            return user, None
    except ValueError:
        pass
    lowered = identifier.lower()
    for column in (User.username, User.email, User.name):
        if column is User.email and "@" not in lowered:
            continue
        res = await db.execute(select(User).where(func.lower(column) == lowered).limit(2))
        hits = list(res.scalars())
        if len(hits) == 1:
            return hits[0], None
        if len(hits) > 1:
            return None, f"identifier '{identifier}' 命中多条 {column.key},请改用 UUID"
    return None, f"找不到用户 '{identifier}'"


@dataclass
class Row:
    """表格一行 = 一个绑定意图(用户 x 归一化手机号)及其裁决结果。"""

    user: User
    phone: str | None = None  # 归一化后的候选/指定手机号;无候选为 None
    action: str = "skip"  # bind | skip | conflict
    reason: str = ""  # 动作说明 / 冲突原因
    source: str = "scan"  # scan(username 扫描)| csv(人工指定)


async def build_plan(db: AsyncSession, csv_pairs: list[tuple[str, str]]) -> tuple[list[Row], list[str]]:
    """扫描 + 冲突裁决,产出逐用户动作表。冲突一律标记 conflict,绝不写库。"""
    res = await db.execute(select(User).order_by(User.name))
    users: list[User] = list(res.scalars())

    rows: dict[uuid.UUID, Row] = {}
    for u in users:
        if u.phone:
            rows[u.id] = Row(u, reason=f"已有手机号 {mask_phone(u.phone)},幂等跳过")
        elif not u.username:
            rows[u.id] = Row(u, reason="无 username,不自动绑定")
        else:
            try:
                candidate = normalize_phone(u.username)
            except InvalidPhone:
                rows[u.id] = Row(u, reason="username 非手机号形态,不自动绑定")
            else:
                rows[u.id] = Row(u, phone=candidate, action="bind", reason="username 即手机号(D5 归一化命中)")

    # --csv 解析:identifier 解析失败 / phone 格式非法 → 进解析失败名单(按冲突计)
    csv_errors: list[str] = []
    pair_count_by_user: dict[uuid.UUID, int] = {}
    for identifier, raw_phone in csv_pairs:
        try:
            phone = normalize_phone(raw_phone)
        except InvalidPhone:
            csv_errors.append(f"identifier={identifier!r}:phone 格式不正确({raw_phone!r},D5 归一化失败)")
            continue
        user, err = await find_user_unique(db, identifier)
        if user is None:
            csv_errors.append(f"identifier={identifier!r}:{err}(phone={phone})")
            continue
        pair_count_by_user[user.id] = pair_count_by_user.get(user.id, 0) + 1
        # --csv 指定优先级高于扫描候选(冲突人工裁决的正道);同用户重复见下
        rows[user.id] = Row(user, phone=phone, action="bind", reason="--csv 指定绑定", source="csv")

    # c) --csv 双给(用户维度):同一用户重复出现 → 一律冲突(重复即冲突,同值也不放行)
    for uid, n in pair_count_by_user.items():
        if n > 1:
            rows[uid].action = "conflict"
            rows[uid].reason = f"--csv 双给:同一用户被指定 {n} 次(请去重后二跑)"

    # 目标用户已有手机号:同号 → 幂等 skip;异号 → 冲突(脚本绝不覆盖既有绑定)
    for row in rows.values():
        if row.source == "csv" and row.action == "bind" and row.user.phone:
            if row.phone == row.user.phone:
                row.action, row.reason = "skip", "已绑定该手机号(幂等跳过)"
            else:
                row.action = "conflict"
                row.reason = f"目标用户已有手机号 {mask_phone(row.user.phone)},脚本不覆盖(须先人工解除原绑定)"

    # c) --csv 双给(号码维度):同一手机号被指给多个用户 → 全部冲突
    csv_by_phone: dict[str, list[Row]] = {}
    for row in rows.values():
        if row.source == "csv" and row.action == "bind" and row.phone:
            csv_by_phone.setdefault(row.phone, []).append(row)
    for group in csv_by_phone.values():
        if len(group) > 1:
            for r in group:
                r.action = "conflict"
                r.reason = "--csv 双给:该手机号同时指给多个用户"

    # b)/d) 占用冲突:候选号已被其他用户持有(DB 实时状态,--csv 二跑同样拒绝)
    occupied = {u.phone: u for u in users if u.phone}
    for row in rows.values():
        if row.action != "bind" or row.phone is None:
            continue
        holder = occupied.get(row.phone)
        if holder is not None and holder.id != row.user.id:
            row.action = "conflict"
            row.reason = (
                f"手机号已被其他用户占用({holder.username or holder.name},"
                "须先人工解除原绑定,脚本绝不覆盖唯一约束)"
            )

    # --csv 已指定归属:该手机号的其余 scan 候选不再自动绑(以人工裁决为准)。
    # 覆盖两类:指定已生效 →「已由 --csv 指定归属」;指定自身冲突未生效 → 防误绑
    # 同样不自动绑(根因见该 --csv 行的冲突原因,复核后二跑)。
    csv_claims = {r.phone: (r.user.id, r.action) for r in rows.values() if r.source == "csv" and r.phone}
    for row in rows.values():
        claim = csv_claims.get(row.phone) if row.phone else None
        if row.source != "scan" or row.action != "bind" or claim is None:
            continue
        claim_uid, claim_action = claim
        if claim_uid == row.user.id:
            continue
        if claim_action == "bind":
            row.action, row.reason = "skip", "该手机号已由 --csv 指定归属(以人工裁决为准)"
        else:
            row.action = "skip"
            row.reason = "该手机号被 --csv 指定给他用户但该指定未生效(见冲突名单),防误绑不自动绑定"

    # a) 归一化折叠:同号仍有多个 scan 候选(未被 --csv 裁决)→ 全部候选进冲突名单
    scan_by_phone: dict[str, list[Row]] = {}
    for row in rows.values():
        if row.source == "scan" and row.action == "bind" and row.phone:
            scan_by_phone.setdefault(row.phone, []).append(row)
    for group in scan_by_phone.values():
        if len(group) > 1:
            for r in group:
                r.action = "conflict"
                r.reason = "归一化折叠:该手机号对应多个 username(人工裁决后 --csv 指定归属)"

    return list(rows.values()), csv_errors


def print_report(rows: list[Row], csv_errors: list[str]) -> None:
    """dry-run / apply 共用的表格输出(用户ID/username/phone/动作/说明)。"""
    print(f"\n扫描完成:共 {len(rows)} 个用户")
    print(f"{'用户ID':<38} {'username':<20} {'phone':<15} {'动作':<9} 说明")
    for r in rows:
        if r.phone:
            phone = r.phone
        elif r.user.phone:
            phone = mask_phone(r.user.phone)
        else:
            phone = "-"
        print(f"{r.user.id!s:<38} {r.user.username or '-':<20} {phone:<15} {r.action:<9} {r.reason}")
    if csv_errors:
        print("\n--csv 解析失败(按冲突计,未写库):")
        for e in csv_errors:
            print(f"  - {e}")


def print_summary(rows: list[Row], csv_errors: list[str]) -> int:
    """汇总:bind/skip/conflict 计数 + 冲突名单明细;返回 bind 数。"""
    n_bind = sum(1 for r in rows if r.action == "bind")
    n_skip = sum(1 for r in rows if r.action == "skip")
    n_conflict = sum(1 for r in rows if r.action == "conflict") + len(csv_errors)
    print(
        f"\n汇总:bind {n_bind} / skip {n_skip} / conflict {n_conflict}"
        f"(含 --csv 解析失败 {len(csv_errors)} 条)"
    )
    conflicts = [r for r in rows if r.action == "conflict"]
    if conflicts:
        print("冲突名单(全部未写库;人工裁决后可用 --csv 指定归属二跑):")
        for r in conflicts:
            print(
                f"  - {r.user.username or r.user.name} user_id={r.user.id} "
                f"phone={r.phone or '-'} 原因:{r.reason}"
            )
    return n_bind


async def apply_rows(sm: Any, bind_rows: list[Row]) -> tuple[int, int]:
    """逐条实绑:UPDATE users.phone + 审计 phone_bound(独立 session,幂等可重跑)。

    事务边界照 set_password.py 先例:数据写入与审计分 session,audit.write 自带
    commit;并发窗口由 uq_users_phone 兜底(IntegrityError → 该行进冲突不中断)。
    """
    bound = raced = 0
    for row in bind_rows:
        async with sm() as db:
            user = await db.get(User, row.user.id)
            if user is None:
                row.action, row.reason = "conflict", "实跑时用户已不存在"
                continue
            if user.phone:  # 计划之后他人已绑(并发窗口)→ 绝不覆盖
                row.action, row.reason = "skip", f"实跑时发现已有手机号 {mask_phone(user.phone)},未覆盖"
                raced += 1
                continue
            old_masked = None  # 走到这里必为首次绑定;字段照 router 口径保留(old 或 None)
            user.phone = row.phone
            try:
                await db.commit()
            except IntegrityError:
                await db.rollback()
                row.action, row.reason = "conflict", "并发占用被 uq_users_phone 唯一约束拒绝"
                continue
        # 独立 session 写审计;audit.write 自带 commit(set_password.py 同款)
        async with sm() as audit_db:
            await AuditService(audit_db).write(
                event_type="phone_bound",
                details={
                    "actor": "cli",
                    "source": "backfill",
                    "old_masked": old_masked,
                    "new_masked": mask_phone(row.phone) if row.phone else "",
                },
            )
        bound += 1
    return bound, raced


async def main() -> None:
    args = parse_args()
    csv_pairs: list[tuple[str, str]] = []
    if args.csv:
        csv_pairs = parse_csv(args.csv)

    sm = get_sessionmaker()
    async with sm() as db:
        rows, csv_errors = await build_plan(db, csv_pairs)
    print_report(rows, csv_errors)
    n_bind = print_summary(rows, csv_errors)

    if not args.apply:
        print("dry-run 完成(未写库;实跑加 --apply,且必须显式搭配 --yes)")
        return
    if not args.yes:
        print("未写库:--apply 必须显式搭配 --yes 才会实跑(防误操作)。")
        return
    if n_bind == 0:
        print("无可绑定行(bind 0),未写库。")
        return
    bind_rows = [r for r in rows if r.action == "bind"]
    bound, raced = await apply_rows(sm, bind_rows)
    print(f"实跑完成:绑定 {bound} 条(并发窗口跳过 {raced} 条);幂等可重跑(已绑的仍 skip)。")


if __name__ == "__main__":
    asyncio.run(main())
