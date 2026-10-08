"""百度网盘 token 落库加密 — Fernet 对称加密(方案 §5.1)。

密钥来源(优先级):
  1. settings.baidu_token_enc_key 显式配置(生产推荐)
  2. 未配置 → 由 sha256(settings.session_jwt_secret) 派生 Fernet key(启动打
     warning:跨用途复用 JWT 密钥应被运维感知,方案 §11 运维预期)

两个来源统一走 sha256 派生:任意 passphrase 材料都可用(不要求 base64 格式的
Fernet key),轮换语义两边一致。

轮换影响(运维注意,方案 §5.1/§11):更改派生源(JWT 密钥或显式 ENC_KEY)后旧
密文解密失败 → 绑定按 expired 处理需重新授权;密文不可恢复,无迁移通道。
"""
from __future__ import annotations

import base64
import hashlib
import logging

from cryptography.fernet import Fernet, InvalidToken

from app.settings import Settings

log = logging.getLogger(__name__)


class TokenDecryptError(Exception):
    """密文解密失败(密钥轮换/密文损坏)— 调用方按绑定 expired 处理(方案 §5.1)。"""


def derive_fernet_key(secret: str) -> bytes:
    """sha256(secret) → 32 字节 → urlsafe_base64 → Fernet key(纯函数,单测友好)。"""
    return base64.urlsafe_b64encode(hashlib.sha256(secret.encode("utf-8")).digest())


def encrypt_str(fernet: Fernet, plaintext: str) -> str:
    """加密字符串 token,返回可落库的密文(纯函数,单测友好)。"""
    return fernet.encrypt(plaintext.encode("utf-8")).decode("ascii")


def decrypt_str(fernet: Fernet, ciphertext: str) -> str:
    """解密密文;失败抛 TokenDecryptError(不裸抛 InvalidToken,隔离 cryptography 类型)。"""
    try:
        return fernet.decrypt(ciphertext.encode("ascii")).decode("utf-8")
    except InvalidToken as e:
        raise TokenDecryptError(
            "token 密文解密失败(加密密钥可能已轮换,绑定需重新授权)"
        ) from e


class TokenCryptoService:
    """绑定 token 的加密/解密;实例挂 app.state.token_crypto(lifespan 构造)。"""

    def __init__(self, settings: Settings) -> None:
        if settings.baidu_token_enc_key:
            self._fernet = Fernet(derive_fernet_key(settings.baidu_token_enc_key))
        else:
            log.warning(
                "BAIDU_TOKEN_ENC_KEY 未配置,回退用 sha256(session_jwt_secret) 派生"
                " Fernet 密钥(生产建议显式配置;派生源轮换会使绑定失效需重新授权)"
            )
            self._fernet = Fernet(derive_fernet_key(settings.session_jwt_secret))

    def encrypt(self, plaintext: str) -> str:
        return encrypt_str(self._fernet, plaintext)

    def decrypt(self, ciphertext: str) -> str:
        return decrypt_str(self._fernet, ciphertext)
