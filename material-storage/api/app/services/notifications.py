"""应用内通知中心 + 可选 SMTP — #153(ADR-0007 弃飞书后的最小通知通道)。

职责:
- `create_notification` — 单条通知落库(notifications 表,#148 已建)+ 可选 SMTP 邮件
- 业务写入口(由 routers/approvals.py / routers/folders.py / routers/share.py 的
  BackgroundTask 直接调用;#154 删除 approvals_notify.py / invite_notify.py 不影响本模块):
  - notify_approval_pending — 申请提交 → 给 target admin 写"待审"通知
  - notify_approval_decided — 审批完成 → 给申请人写结果通知
  - notify_folder_invite    — 敏感目录邀请 → 给被邀请人写通知
  (#162 下线 IM 后分享为纯链接模式、无接收人概念,不产生分享通知)

设计:
- 轮询即可(不做 WebSocket);SMTP 留空 = no-op 零报错(验收硬项)
- 全部 best-effort:失败仅 log,不影响调用方主流程 / IM 卡片
- 站内通知邮件走独立开关 NOTIFY_EMAIL_ENABLED(默认 false,方案 §5.1):
  填 SMTP 不会自动发通知邮件;实际发送统一走 services/mailer.send_mail
- 服务实例走参数注入(db session / permissions / audit),不搞模块级单例
"""
from __future__ import annotations

import logging
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.tables import ApprovalRequest, Folder, Notification, Project, User
from app.services import mailer
from app.services.audit import AuditService
from app.services.email_utils import mask_email
from app.services.mailer import MailSendError
from app.services.permissions import PermissionsService
from app.services.target_resolve import resolve_target_name_and_project
from app.settings import Settings, get_settings

log = logging.getLogger(__name__)

# 通知 kind 白名单(notifications.kind 列 String(32))— 前端 NOTIFICATION_KIND_LABEL 同步
KIND_APPROVAL_PENDING = "approval_pending"
KIND_APPROVAL_DECIDED = "approval_decided"
KIND_FOLDER_INVITE = "folder_invite"

VALID_KINDS = frozenset({
    KIND_APPROVAL_PENDING, KIND_APPROVAL_DECIDED, KIND_FOLDER_INVITE,
})


# ─── 落库 + 邮件 ──────────────────────────────────────────────────────────────
async def create_notification(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    kind: str,
    title: str,
    body: str | None = None,
    link: str | None = None,
) -> None:
    """写一条应用内通知;SMTP + NOTIFY_EMAIL_ENABLED 开启后同步发邮件。best-effort。"""
    if kind not in VALID_KINDS:
        log.warning("create_notification: unknown kind=%s (skipped)", kind)
        return
    db.add(Notification(user_id=user_id, kind=kind, title=title, body=body, link=link))
    try:
        await db.commit()
    except Exception:
        log.exception("create_notification commit fail user=%s kind=%s", user_id, kind)
        return

    settings = get_settings()
    # 站内通知邮件独立开关(方案 §5.1):填 SMTP 不会自动打开它 —— 审批/邀请
    # 收件人是管理员手填的(可能未验证/录错的)地址,须产品确认后才开启
    if not (settings.notify_email_enabled and settings.smtp_enabled):
        return
    user = await db.get(User, user_id)
    if user is None or not user.email:
        return  # 无邮箱地址不发;应用内通知已落库
    await _maybe_send_email(
        settings, to_email=user.email, title=title, body=body, link=link,
    )


async def _maybe_send_email(
    settings: Settings, *, to_email: str, title: str, body: str | None, link: str | None,
) -> None:
    """经 services/mailer.send_mail 发送(to_thread 在 mailer 内)。失败仅脱敏 log。"""
    if not settings.smtp_enabled:
        return
    text = "\n\n".join(part for part in (title, body or "", link or "") if part)
    try:
        await mailer.send_mail(settings, to=to_email, subject=title, body=text)
    except MailSendError as exc:
        # best-effort:不影响主流程;日志只出现脱敏收件人(方案 §5.6.1/§12-10)
        log.warning("notification email not sent (definite=%s) to=%s title=%r err=%s",
                    exc.definite, mask_email(to_email), title[:80], exc)


# ─── 审批:待办(给 target admin)──────────────────────────────────────────────
async def notify_approval_pending(
    *,
    approval_id: uuid.UUID,
    db: AsyncSession,
    permissions: PermissionsService,
    audit: AuditService,
) -> None:
    """申请提交 → 给 target 的 admin 各写一条"待审"通知。best-effort。"""
    approval = await db.get(ApprovalRequest, approval_id)
    if approval is None:
        return
    admin_ids = await _admins_for_target(db, permissions, approval)
    if not admin_ids:
        log.debug("notify_approval_pending: no active admin for approval=%s", approval_id)
        return

    target_name, project_id = await resolve_target_name_and_project(
        db, approval.target_type, approval.target_id,
    )
    target_label = target_name or f"{approval.target_type}:{approval.target_id}"
    applicant = await db.get(User, approval.applicant_user_id)
    applicant_name = applicant.name if applicant else "未知用户"
    action_label = _action_label(approval)

    settings = get_settings()
    title = f"新的权限申请:{applicant_name} 请求{action_label}「{target_label}」"
    body = f"理由:{approval.reason[:500] or '(无)'}"
    link = _web_url(settings, "approvals")
    for aid in admin_ids:
        await create_notification(
            db, user_id=aid, kind=KIND_APPROVAL_PENDING, title=title, body=body, link=link,
        )

    await audit.write(
        event_type="notification_sent",
        actor_user_id=approval.applicant_user_id,
        target_project_id=project_id,
        details={
            "kind": KIND_APPROVAL_PENDING,
            "approval_id": str(approval.id),
            "recipient_user_ids": [str(a) for a in admin_ids],
        },
    )


# ─── 审批:结果(给申请人)─────────────────────────────────────────────────────
async def notify_approval_decided(
    *,
    approval_id: uuid.UUID,
    db: AsyncSession,
    audit: AuditService,
) -> None:
    """审批完成 → 给申请人写结果通知(approved / rejected)。best-effort。"""
    approval = await db.get(ApprovalRequest, approval_id)
    if approval is None or approval.status not in ("approved", "rejected"):
        return
    applicant = await db.get(User, approval.applicant_user_id)
    if applicant is None or not applicant.is_active:
        return

    target_name, project_id = await resolve_target_name_and_project(
        db, approval.target_type, approval.target_id,
    )
    target_label = target_name or f"{approval.target_type}:{approval.target_id}"
    decider = (
        await db.get(User, approval.approver_user_id) if approval.approver_user_id else None
    )
    decision_text = "已通过" if approval.status == "approved" else "已拒绝"

    settings = get_settings()
    title = f"权限申请{decision_text}:{target_label}"
    body = f"审批人:{decider.name if decider else '(系统)'}"
    if approval.decision_note:
        body += f"\n备注:{approval.decision_note[:500]}"
    await create_notification(
        db, user_id=applicant.id, kind=KIND_APPROVAL_DECIDED,
        title=title, body=body, link=_web_url(settings, "approvals"),
    )

    await audit.write(
        event_type="notification_sent",
        actor_user_id=approval.approver_user_id,
        target_project_id=project_id,
        details={
            "kind": KIND_APPROVAL_DECIDED,
            "approval_id": str(approval.id),
            "decision": approval.status,
            "recipient_user_ids": [str(applicant.id)],
        },
    )


# ─── 敏感目录邀请(给被邀请人)───────────────────────────────────────────────
async def notify_folder_invite(
    *,
    folder_id: uuid.UUID,
    invitee_user_id: uuid.UUID,
    inviter_user_id: uuid.UUID,
    duration_seconds: int | None,
    db: AsyncSession,
    audit: AuditService,
) -> None:
    """admin 邀请 user 进 sensitive_folder → 给被邀请人写通知。best-effort。"""
    invitee = await db.get(User, invitee_user_id)
    if invitee is None or not invitee.is_active:
        log.debug("notify_folder_invite: invitee %s inactive/missing — skip", invitee_user_id)
        return
    folder = await db.get(Folder, folder_id)
    if folder is None:
        log.warning("notify_folder_invite: folder %s not found", folder_id)
        return
    project = await db.get(Project, folder.project_id)
    inviter = await db.get(User, inviter_user_id)

    duration_label = _duration_label(duration_seconds) if duration_seconds else "永久"
    settings = get_settings()
    link = _web_url(settings, "projects", str(folder.project_id), "folders", str(folder_id))
    title = f"你已被邀请加入敏感目录「{folder.name}」"
    body = (
        f"邀请人:{inviter.name if inviter else '(未知)'}\n"
        f"期限:{duration_label}\n"
        f"位置:{project.name if project else '?'} / {folder.name}"
    )
    await create_notification(
        db, user_id=invitee.id, kind=KIND_FOLDER_INVITE, title=title, body=body, link=link,
    )

    await audit.write(
        event_type="notification_sent",
        actor_user_id=inviter_user_id,
        target_project_id=folder.project_id,
        details={
            "kind": KIND_FOLDER_INVITE,
            "folder_id": str(folder_id),
            "permanent": duration_seconds is None,
            "duration_seconds": duration_seconds,
            "recipient_user_ids": [str(invitee.id)],
        },
    )


async def run_notify_approval_pending_bg(
    *,
    approval_id: uuid.UUID,
    permissions: PermissionsService,
) -> None:
    """FastAPI BackgroundTasks 入口 — 自开 db session,失败仅 log。

    由 routers/approvals.py 申请提交端点注册;独立于 IM 卡片(approvals_notify.py
    将被 #154 删除,这里不依赖它)。
    """
    from app.db.session import get_sessionmaker
    try:
        async with get_sessionmaker()() as db:
            audit = AuditService(db)
            await notify_approval_pending(
                approval_id=approval_id, db=db, permissions=permissions, audit=audit,
            )
    except Exception:
        log.exception("run_notify_approval_pending_bg failed approval=%s", approval_id)


async def run_notify_approval_decided_bg(
    *,
    approval_id: uuid.UUID,
) -> None:
    """FastAPI BackgroundTasks 入口 — 自开 db session,失败仅 log。"""
    from app.db.session import get_sessionmaker
    try:
        async with get_sessionmaker()() as db:
            audit = AuditService(db)
            await notify_approval_decided(approval_id=approval_id, db=db, audit=audit)
    except Exception:
        log.exception("run_notify_approval_decided_bg failed approval=%s", approval_id)


async def run_notify_folder_invite_bg(
    *,
    folder_id: uuid.UUID,
    invitee_user_id: uuid.UUID,
    inviter_user_id: uuid.UUID,
    duration_seconds: int | None,
) -> None:
    """FastAPI BackgroundTasks 入口 — 自开 db session,失败仅 log。

    由 routers/folders.py 敏感目录邀请端点注册(user 类型邀请才注册,与 IM 卡片一致)。
    """
    from app.db.session import get_sessionmaker
    try:
        async with get_sessionmaker()() as db:
            audit = AuditService(db)
            await notify_folder_invite(
                folder_id=folder_id,
                invitee_user_id=invitee_user_id,
                inviter_user_id=inviter_user_id,
                duration_seconds=duration_seconds,
                db=db,
                audit=audit,
            )
    except Exception:
        log.exception("run_notify_folder_invite_bg failed folder=%s", folder_id)


# ─── helpers ──────────────────────────────────────────────────────────────────
async def _admins_for_target(
    db: AsyncSession,
    permissions: PermissionsService,
    approval: ApprovalRequest,
) -> list[uuid.UUID]:
    """target 的 can_admin 用户(users.id UUID;去 inactive)。

    与 approvals_notify._admin_open_ids_for_target 同源但只关心 user UUID —
    应用内通知不需要飞书 open_id。
    """
    admin_ids = await permissions.list_users_with_relation(
        object_type=approval.target_type,
        object_id=str(approval.target_id),
        relation="can_admin",
    )
    admin_uuids: list[uuid.UUID] = []
    for s in admin_ids:
        try:
            admin_uuids.append(uuid.UUID(s))
        except ValueError:
            continue  # 老 open_id 存量 subject,跳过
    if not admin_uuids:
        return []
    stmt = select(User.id).where(User.id.in_(admin_uuids), User.is_active.is_(True))
    res = await db.execute(stmt)
    return list(res.scalars().all())


def _action_label(approval: ApprovalRequest) -> str:
    dur = approval.duration_seconds
    dur_label = _duration_label(dur) if dur else None
    if approval.action == "download":
        return f"临时下载({dur_label})" if dur_label else "临时下载"
    if approval.action == "access":
        return "临时加入" if dur_label else "加入"
    return approval.action


def _duration_label(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds} 秒"
    if seconds < 3600:
        return f"{seconds // 60} 分钟"
    if seconds < 86400:
        h = seconds / 3600
        return f"{int(h)} 小时" if h.is_integer() else f"{h:.1f} 小时"
    d = seconds / 86400
    return f"{int(d)} 天" if d.is_integer() else f"{d:.1f} 天"


def _web_url(settings: Settings, *parts: str) -> str:
    base = settings.web_app_base_url.rstrip("/") + "/"
    return base + "/".join(p.strip("/") for p in parts)
