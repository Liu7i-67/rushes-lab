#!/usr/bin/env bash
# 分片推送单个本地文件到 hh2 —— 隧道对 ~1MB 以上的长流不稳定(实测 ~800KB 处断流),
# 每 512KB 一片、每片一条新 ssh 流,失败自动重试;远端拼接后 md5 校验。
# 用法: bash chunked-push.sh <本地文件> <远端绝对路径>
# 例:   bash chunked-push.sh /tmp/ms-spa.tgz /tmp/ms-spa.tgz
set -euo pipefail

LOCAL="${1:-}"; REMOTE="${2:-}"
[ -f "$LOCAL" ] || { echo "ERROR: 本地文件不存在: $LOCAL" >&2; exit 2; }
[ -n "$REMOTE" ] || { echo "用法: $0 <本地文件> <远端绝对路径>" >&2; exit 2; }

HOST=hh2
CHUNK=512k
RDIR=$(dirname "$REMOTE")

# 远端目标目录必须先建:scp 报 "No such file or directory" 多半就是它
ssh -o ConnectTimeout=8 "$HOST" "mkdir -p '$RDIR'"

TMP="${LOCAL}.chunks"
rm -rf "$TMP" && mkdir -p "$TMP"
split -b "$CHUNK" -d "$LOCAL" "$TMP/part."

MD5_LOCAL=$(md5sum "$LOCAL" | cut -d' ' -f1)
total=$(ls "$TMP"/part.* | wc -l | tr -d ' ')
echo "推送 $LOCAL ($(du -h "$LOCAL" | cut -f1), $total 片) → $HOST:$REMOTE"

n=0
for f in "$TMP"/part.*; do
  n=$((n + 1))
  base=$(basename "$f")
  ok=0
  for try in 1 2 3 4 5; do
    # ServerAlive:10s 心跳 ×3 次无响应即判死重连,不傻等
    if scp -q -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
         "$f" "$HOST:$RDIR/$base"; then
      ok=1; break
    fi
    echo "  ⚠ $base 第 $try 次传输失败,3s 后重试" >&2
    sleep 3
  done
  if [ "$ok" != 1 ]; then
    echo "ERROR: $base 连续 5 次失败,放弃(远端可能残留部分分片,重跑本脚本即可覆盖)" >&2
    exit 1
  fi
  echo "  [$n/$total] $base ✓"
done

ssh -o ConnectTimeout=8 "$HOST" "cat '$RDIR'/part.* > '$REMOTE' && rm -f '$RDIR'/part.*"

MD5_REMOTE=$(ssh -o ConnectTimeout=8 "$HOST" "md5sum '$REMOTE' | cut -d' ' -f1")
if [ "$MD5_LOCAL" != "$MD5_REMOTE" ]; then
  echo "ERROR: md5 不匹配 本地=$MD5_LOCAL 远端=$MD5_REMOTE(删除远端文件后重跑)" >&2
  exit 1
fi

rm -rf "$TMP"
echo "✓ $REMOTE ($MD5_REMOTE)"
