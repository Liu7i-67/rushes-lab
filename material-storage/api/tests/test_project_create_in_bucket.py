"""ProjectCreateIn.minio_bucket 格式约束(2026-10-22 第四批 B1)纯模型单测。

前端(web + app)已把 bucket 收敛为单选下拉,本约束是 API 直调兜底:
任意桶名会创建成功但首次上传即 NoSuchBucket 500,且项目 bucket 无 API 可改。

不依赖 DB / 容器:`uv run pytest tests/test_project_create_in_bucket.py` 可跑。
"""
from __future__ import annotations

import uuid

import pytest
from pydantic import ValidationError

from app.models import ProjectCreateIn

VALID = ["ms-dev", "abc", "a1-b2", "a" * 63]
INVALID = [
    "MS-DEV",      # 大写
    "ms_dev",      # 下划线
    "ab",          # 过短
    "-abc",        # 首字符连字符
    "abc-",        # 尾字符连字符
    "a" * 64,      # 超长
    "",            # 空串(原 max_length 允许,现被 pattern/min_length 拦)
]


def _payload(bucket: str) -> dict:
    # 只构造必填字段:code / name / minio_bucket / admin_user_id
    # (organization_id、description、initial_grants、folder_template_id、
    #  artist_account 均可选;其余字段缺失导致的 ValidationError 会污染断言)
    return {
        "code": "demo-1",
        "name": "演示",
        "minio_bucket": bucket,
        "admin_user_id": uuid.uuid4(),
    }


@pytest.mark.parametrize("bucket", VALID)
def test_valid_bucket(bucket):
    m = ProjectCreateIn(**_payload(bucket))
    assert m.minio_bucket == bucket


@pytest.mark.parametrize("bucket", INVALID)
def test_invalid_bucket(bucket):
    with pytest.raises(ValidationError):
        ProjectCreateIn(**_payload(bucket))
