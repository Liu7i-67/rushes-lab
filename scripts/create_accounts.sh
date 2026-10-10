#!/usr/bin/env bash
#
# create_accounts.sh — 批量创建 material-storage 账号(运维脚本)
#
# 读取人员名单 csv(列序: 部门,组别,运营,角色,账号;UTF-8 with BOM / CRLF 兼容),
# 逐行调用 admin directory API 创建账号、把服务端生成的临时密码写回该行第 6 列,
# 并按「角色」列把用户加入同名用户组(组不存在则自动创建)。
#
# 用法: bash create_accounts.sh <csv路径> [--base <API_BASE>] [--dry-run] [--force]
#       ADMIN_USER / ADMIN_PASS 环境变量提供管理员凭证(或运行时交互输入,输入不回显)
# 默认: --base http://127.0.0.1(hh2 nginx 入口);dev 测试传 --base http://127.0.0.1:8090
#
# 依赖: bash 4+ / curl / awk / sed / grep / od / paste(禁 jq、python;目标环境 hh2-prod 宿主机)。
# 凭证绝不写入日志、audit 或本脚本(决策 D9)。
#
# 关键行为(需求依据 docs/qdev/2026-10-09-account-batch-create.md):
#   - 只登录一次拿 cookie;401/429 立即退出不重试(同用户名失败 5 次锁 15 分钟)。
#   - 建号 201 → temporary_password 写第 6 列(权威值);409 → 跳过建号仍补加组,
#     原第 6 列已写入的密码原样保留(决策 D11),无密码部分才写「已存在,补加组」。
#   - 加成员 409(已在组中)视为成功;单行任何失败不中断整体,结束输出统计与失败行清单。
#   - 全空行原样保留;写回前备份 <csv>.bak;默认第 6 列已非空的行跳过(--force 重处理)。
#   - --dry-run 只解析并打印执行计划,不登录、不调任何 API、不写 csv。

set -uo pipefail
# 注意: 故意不开 set -e —— 单行建号/加组失败必须 continue 而非整体退出,
# 所有 curl / 文件操作的返回码在下方逐处显式判断。

BASE="http://127.0.0.1"
DRY_RUN=0
FORCE=0
CSV=""

usage() {
  cat <<'USAGE'
用法: bash create_accounts.sh <csv路径> [--base <API_BASE>] [--dry-run] [--force]
      ADMIN_USER / ADMIN_PASS 环境变量提供管理员凭证(或运行时交互输入,输入不回显)
默认: --base http://127.0.0.1(hh2 nginx 入口);dev 测试传 --base http://127.0.0.1:8090
  --dry-run  只解析并输出执行计划,不登录、不调任何 API、不改 csv
  --force    第 6 列已有结果的行也强制重处理(默认跳过)
USAGE
}

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "[错误] $*" >&2; }

# ─── JSON 小工具(无 jq 可用;响应为简单 flat JSON,按 grep/sed 提取)─────────
json_str() {  # $1=值 → 输出带引号 JSON 字符串(防御性转义 \ 与 ";本表数据无此风险)
  local t="$1"
  t="${t//\\/\\\\}"
  t="${t//\"/\\\"}"
  printf '"%s"' "$t"
}
jstr() {  # 从 $RESP(单个 flat JSON 对象)提取第一个 "$1":"..." 的值
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | head -n 1
}
# ─── 原第 6 列密码部分提取(决策 D11)────────────────────────────────────────
# temporary_password 只回显一次,--force 重跑 409 时任何情况不得覆盖丢失已写入密码。
# 规则: 去掉「|加组失败:...」后缀(若有)后,剩余部分非空且不以状态前缀
# (已存在/跳过/失败)开头,才视为密码;否则视为无密码部分(输出空串)。
extract_pw_part() {  # $1=原第 6 列值 → 输出密码部分(无则空串),恒返回 0
  local v="${1%%|加组失败:*}"
  case "$v" in
    "" | 已存在* | 跳过* | 失败*) : ;;
    *) printf '%s' "$v" ;;
  esac
  return 0
}

# 在 $RESP(flat 对象数组)中逐对象定位: match_key 的值精确等于 match_value 的
# 那个对象,返回其 want_key 的值。先按 },{ 切分对象(接口返回均为无嵌套 flat 对象),
# 避免多对象间 grep 行序错位;username 可为 null,带引号匹配天然跳过 null。
extract_match() {  # $1=want_key $2=match_key $3=match_value(精确)
  sed 's/},{/}\n{/g' "$RESP" | awk -v wk="$1" -v mk="$2" -v mv="$3" '
    {
      pat = "\"" mk "\"[[:space:]]*:[[:space:]]*\"" mv "\""
      if ($0 ~ pat) {
        p2 = "\"" wk "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
        if (match($0, p2)) {
          v = substr($0, RSTART, RLENGTH)
          sub(/^[^:]*:[[:space:]]*"/, "", v)
          sub(/"$/, "", v)
          print v
          exit
        }
      }
    }'
}

# ─── API 调用封装(统一带 cookie;结果: API_CODE + $RESP)────────────────────
API_CODE="000"
api_call() {  # $1=METHOD $2=path $3=JSON body(可空)
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --connect-timeout 5 --max-time 30
              -o "$RESP" -w '%{http_code}'
              -b "$COOKIE_JAR" -X "$method"
              "$BASE/api/v1/admin/directory${path}")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
  API_CODE="$(curl "${args[@]}")" || API_CODE="000"
  return 0
}
api_get_q() {  # $1=path $2=查询参数名 $3=值(curl -G --data-urlencode 处理中文编码)
  API_CODE="$(curl -sS --connect-timeout 5 --max-time 30 \
    -o "$RESP" -w '%{http_code}' -b "$COOKIE_JAR" \
    -G "$BASE/api/v1/admin/directory$1" --data-urlencode "$2=$3")" || API_CODE="000"
  return 0
}

# ─── 组名 → group_id(带缓存;不存在自动建组,409 复用;决策 D3)──────────────
declare -A GID_CACHE=()
GF_ERR=""
resolve_group() {  # $1=组名;成功 echo gid 返回 0;失败 GF_ERR=原因 返回 1
  local name="$1" gid=""
  GF_ERR=""
  if [ -n "${GID_CACHE[$name]:-}" ]; then
    printf '%s' "${GID_CACHE[$name]}"
    return 0
  fi
  api_get_q "/groups" "q" "$name"
  if [ "$API_CODE" != "200" ]; then
    GF_ERR="查组 HTTP $API_CODE"
    return 1
  fi
  gid="$(extract_match "id" "name" "$name")"
  if [ -n "$gid" ]; then
    GID_CACHE[$name]="$gid"
    printf '%s' "$gid"
    return 0
  fi
  # 组不存在 → 自动创建同名组
  api_call "POST" "/groups" "$(printf '{"name":%s}' "$(json_str "$name")")"
  if [ "$API_CODE" = "201" ]; then
    gid="$(jstr "id")"
  elif [ "$API_CODE" = "409" ]; then
    # 重名已存在 → 复用:再精确查一次
    api_get_q "/groups" "q" "$name"
    if [ "$API_CODE" = "200" ]; then
      gid="$(extract_match "id" "name" "$name")"
    fi
  else
    GF_ERR="建组 HTTP $API_CODE"
    return 1
  fi
  if [ -n "$gid" ]; then
    GID_CACHE[$name]="$gid"
    printf '%s' "$gid"
    return 0
  fi
  GF_ERR="建组后仍解析不到组 ID"
  return 1
}

# ─── 参数解析 ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || { err "--base 需要一个参数"; usage; exit 2; }
      BASE="$2"; shift 2 ;;
    --base=*)
      BASE="${1#*=}"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      err "未知参数: $1"; usage; exit 2 ;;
    *)
      if [ -z "$CSV" ]; then CSV="$1"; shift
      else err "多余的参数: $1"; usage; exit 2; fi ;;
  esac
done

[ -n "$CSV" ] || { err "缺少 <csv路径>"; usage; exit 2; }
[ -f "$CSV" ] || { err "csv 不存在: $CSV"; exit 2; }
[ -r "$CSV" ] || { err "csv 不可读: $CSV"; exit 2; }
BASE="${BASE%/}"

# ─── 临时文件 ────────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/create_accounts.XXXXXX")" || {
  err "无法创建临时目录"; exit 1
}
OUT_TMP=""
RESP="$WORK_DIR/resp.json"
cleanup() { rm -rf "$WORK_DIR"; [ -n "$OUT_TMP" ] && rm -f "$OUT_TMP"; return 0; }
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

PLAN="$WORK_DIR/plan.tsv"
COOKIE_JAR="$WORK_DIR/cookies.txt"
FAILED_LIST="$WORK_DIR/failed.txt"
FS_CH=$'\x1f'   # \x1f 计划文件字段分隔符(数据中不会出现;勿用 printf '%c' 31 —— 那会得到字符 "3")

# ─── BOM / 行尾探测 ──────────────────────────────────────────────────────────
HAS_BOM=0
if [ "$(head -c 3 "$CSV" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  HAS_BOM=1
fi
EOL=$'\n'
if grep -q $'\r' "$CSV"; then
  EOL=$'\r\n'
fi

# 读取侧剥离 BOM(写回时按探测结果补回,Excel 兼容)
CSV_SRC="$CSV"
if [ "$HAS_BOM" = "1" ]; then
  CSV_SRC="$WORK_DIR/nobom.csv"
  tail -c +4 "$CSV" > "$CSV_SRC"
fi

# ─── 解析: 生成执行计划 ─────────────────────────────────────────────────────
# 计划字段(\x1f 分隔,共 14 列):
#   1 kind(HEADER|ROW) 2 源行号 3 action 4 mode(RAW=原样保留|WRITE=重写)
#   5-9 原始五列(trim 后,写回保持原五列不变) 10 填充后部门 11 填充后组别
#   12 姓名(部门_组别_运营) 13 第6列现有内容 14 原始行内容(原样保留用)
awk -v FORCE="$FORCE" -v S="$FS_CH" '
function tr(x) { gsub(/^[ \t]+/, "", x); gsub(/[ \t]+$/, "", x); return x }
function join6(a, n,  i, t) {   # 第 6 列起原样拼接(状态文本可能含逗号)
  t = ""
  for (i = 6; i <= n; i++) t = t ((i > 6) ? "," : "") a[i]
  return t
}
NR == 1 {
  raw = $0; sub(/\r$/, "", raw)
  n = split(raw, a, ",")
  c6 = tr(join6(a, n))
  mode = (c6 == "临时密码") ? "RAW" : "WRITE"
  rec = "HEADER" S "1" S "-" S mode
  for (i = 1; i <= 5; i++) rec = rec S tr((i <= n) ? a[i] : "")
  rec = rec S "" S "" S "" S c6 S raw
  print rec
  next
}
{
  raw = $0; sub(/\r$/, "", raw)
  n = split(raw, a, ",")
  for (i = 1; i <= 5; i++) f[i] = tr((i <= n) ? a[i] : "")

  # 部门/组别两列各自独立前向填充(沿列向上找最近非空值,跨空行继承)
  if (f[1] != "") dept = f[1]
  if (f[2] != "") grp  = f[2]

  c6 = tr(join6(a, n))

  # 跳过规则按文档顺序: 全空行 → 运营空 → 账号空 → 角色空
  if (f[1] == "" && f[2] == "" && f[3] == "" && f[4] == "" && f[5] == "") {
    action = "EMPTY"; mode = "RAW"; nm = ""
  } else if (f[3] == "") {
    action = "SKIP_OP"
  } else if (f[5] == "") {
    action = "SKIP_ACC"
  } else if (f[4] == "") {
    action = "SKIP_ROLE"
  } else {
    action = "CREATE"
  }
  if (action != "EMPTY") {
    fd = (f[1] != "") ? f[1] : dept
    fg = (f[2] != "") ? f[2] : grp
    nm = fd "_" fg "_" f[3]          # 空段按空串拼接(决策 D10,dry-run 核对把关)
    mode = ((c6 != "" && FORCE != 1) ? "RAW" : "WRITE")   # 幂等: 第 6 列已非空默认跳过(决策 D7)
  }
  rec = "ROW" S NR S action S mode
  for (i = 1; i <= 5; i++) rec = rec S f[i]
  rec = rec S ((action != "EMPTY") ? fd : "") S ((action != "EMPTY") ? fg : "") S nm
  rec = rec S c6 S raw
  print rec
}
' "$CSV_SRC" > "$PLAN" || { err "csv 解析失败"; exit 1; }

# ─── dry-run: 只打印计划与统计,不登录、不请求、不写 ─────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  log "=== dry-run 执行计划 ==="
  log "csv: $CSV"
  log "base: $BASE(dry-run 不发起任何请求)  force: $FORCE"
  log "------------------------------------------------------------------------------------"
  log "行号    | 动作                      | 姓名 | 登录名 | 角色组"
  log "------------------------------------------------------------------------------------"
  TOTAL=0; N_CREATE=0; N_OP=0; N_ACC=0; N_ROLE=0; N_DONE=0; N_EMPTY=0
  while IFS="$FS_CH" read -r kind linenum action mode o1 o2 o3 o4 o5 fdept fgrp name c6 rawline; do
    if [ "$kind" = "HEADER" ]; then
      if [ "$mode" = "RAW" ]; then
        log "表头    | 表头已有第 6 列,保持原样"
      else
        log "表头    | 追加第 6 列「临时密码」"
      fi
      continue
    fi
    TOTAL=$((TOTAL + 1))
    label=""
    case "$action" in
      CREATE)    label="创建" ;;
      SKIP_OP)   label="跳过:运营为空" ;;
      SKIP_ACC)  label="跳过:账号为空" ;;
      SKIP_ROLE) label="跳过:角色为空" ;;
      EMPTY)     label="空行(原样保留)" ;;
    esac
    if [ "$mode" = "RAW" ] && [ "$action" != "EMPTY" ]; then
      label="跳过:已有结果"
      N_DONE=$((N_DONE + 1))
    else
      case "$action" in
        CREATE)    N_CREATE=$((N_CREATE + 1)) ;;
        SKIP_OP)   N_OP=$((N_OP + 1)) ;;
        SKIP_ACC)  N_ACC=$((N_ACC + 1)) ;;
        SKIP_ROLE) N_ROLE=$((N_ROLE + 1)) ;;
        EMPTY)     N_EMPTY=$((N_EMPTY + 1)) ;;
      esac
    fi
    log "行${linenum} | ${label} | ${name} | ${o5} | ${o4}"
  done < "$PLAN"
  log "------------------------------------------------------------------------------------"
  SKIP_ALL=$((N_OP + N_ACC + N_ROLE + N_DONE))
  log "统计: 总数据行=${TOTAL} | 全空行(原样保留)=${N_EMPTY} | 创建数=${N_CREATE} | 跳过合计=${SKIP_ALL}"
  log "      跳过明细: 运营空=${N_OP} 账号空=${N_ACC} 角色空=${N_ROLE} | 第6列已有结果=${N_DONE}"
  log "dry-run 结束: 未登录、未调用任何 API、未改动 csv。"
  exit 0
fi

# ─── 凭证(仅实跑到达此处;dry-run 永不要求凭证)──────────────────────────────
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
if [ -z "$ADMIN_USER" ]; then
  printf '管理员用户名: '
  read -r ADMIN_USER
fi
if [ -z "$ADMIN_PASS" ]; then
  printf '管理员密码(输入不回显): '
  read -rs ADMIN_PASS
  printf '\n'
fi
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] || { err "缺少管理员凭证(ADMIN_USER/ADMIN_PASS)"; exit 2; }

# ─── 登录一次拿 cookie(失败即退,绝不重试,防触发限流锁定)──────────────────
LOGIN_CODE="$(curl -sS --connect-timeout 5 --max-time 30 \
  -o "$RESP" -w '%{http_code}' \
  -X POST "$BASE/api/v1/auth/local/login" \
  -H 'Content-Type: application/json' \
  --data "$(printf '{"username":%s,"password":%s}' "$(json_str "$ADMIN_USER")" "$(json_str "$ADMIN_PASS")")" \
  -c "$COOKIE_JAR")" || LOGIN_CODE="000"
case "$LOGIN_CODE" in
  200|201)
    : ;;
  401)
    err "登录失败: HTTP 401 凭证错误。不重试(同用户名失败 5 次将锁定 15 分钟)。"
    exit 1 ;;
  429)
    err "登录失败: HTTP 429 触发限流(失败次数过多账号已锁 15 分钟)。立即退出,不重试。"
    exit 1 ;;
  000)
    err "登录失败: 无法连接 $BASE(网络错误)。"
    exit 1 ;;
  *)
    err "登录失败: HTTP $LOGIN_CODE。不重试。"
    exit 1 ;;
esac
log "登录成功: $BASE(ADMIN_USER=$ADMIN_USER)"

# ─── 实跑: 逐行处理 + 增量写回(异常中断不动原 csv)──────────────────────────
OUT_TMP="${CSV}.tmp.$$"
: > "$OUT_TMP" || { err "无法创建临时输出文件: $OUT_TMP"; exit 1; }
if [ "$HAS_BOM" = "1" ]; then
  printf '\xEF\xBB\xBF' > "$OUT_TMP" || { err "写 BOM 失败"; exit 1; }
fi

CREATED=0; EXISTS=0; GFAIL=0; CFAIL=0
SKIP_DONE=0; SKIP_OP_N=0; SKIP_ACC_N=0; SKIP_ROLE_N=0; EMPTY_N=0
CHANGED=0
: > "$FAILED_LIST"

while IFS="$FS_CH" read -r kind linenum action mode o1 o2 o3 o4 o5 fdept fgrp name c6 rawline; do
  # 1) 表头: 已有第 6 列 → 原样保留;否则追加「临时密码」
  if [ "$kind" = "HEADER" ]; then
    if [ "$mode" = "RAW" ]; then
      printf '%s%s' "$rawline" "$EOL" >> "$OUT_TMP"
    else
      printf '%s,%s,%s,%s,%s,%s%s' "$o1" "$o2" "$o3" "$o4" "$o5" "临时密码" "$EOL" >> "$OUT_TMP"
      CHANGED=1
    fi
    continue
  fi

  # 2) 原样保留: 全空行(决策 D6)/ 幂等跳过第 6 列已非空(决策 D7)
  if [ "$mode" = "RAW" ]; then
    printf '%s%s' "$rawline" "$EOL" >> "$OUT_TMP"
    if [ "$action" = "EMPTY" ]; then
      EMPTY_N=$((EMPTY_N + 1))
    else
      SKIP_DONE=$((SKIP_DONE + 1))
      log "行$linenum 跳过:已有结果($c6)"
    fi
    continue
  fi

  # 3) 各类跳过行: 写回状态文本
  st=""
  case "$action" in
    SKIP_OP)   st="跳过:运营为空" ;;
    SKIP_ACC)  st="跳过:账号为空" ;;
    SKIP_ROLE) st="跳过:角色为空" ;;
    CREATE)    st="" ;;
  esac
  if [ -n "$st" ]; then
    printf '%s,%s,%s,%s,%s,%s%s' "$o1" "$o2" "$o3" "$o4" "$o5" "$st" "$EOL" >> "$OUT_TMP"
    CHANGED=1
    case "$action" in
      SKIP_OP)   SKIP_OP_N=$((SKIP_OP_N + 1)) ;;
      SKIP_ACC)  SKIP_ACC_N=$((SKIP_ACC_N + 1)) ;;
      SKIP_ROLE) SKIP_ROLE_N=$((SKIP_ROLE_N + 1)) ;;
    esac
    log "行$linenum $st"
    continue
  fi

  # 4) 待创建行: 建号 + 加组(单行失败只记状态,不中断整体)
  acct="$o5"
  role="$o4"
  pw=""; user_id=""; note=""; gfail=""; existed=""; old_pw=""

  # 2a) 建号: 201 → temporary_password(只回显一次,权威值);409 → 已存在,仍补加组(D1;
  #     --force 重跑时原第 6 列可能已写入密码,写列规则见 2c 与决策 D11)
  api_call "POST" "/users" \
    "$(printf '{"username":%s,"name":%s}' "$(json_str "$acct")" "$(json_str "$name")")"
  case "$API_CODE" in
    2??)
      CREATED=$((CREATED + 1))
      pw="$(jstr "temporary_password")"
      user_id="$(jstr "id")"
      [ -n "$pw" ] || note="失败:建号响应未含临时密码"
      [ -n "$user_id" ] || { [ -n "$note" ] && note="$note,且未取到用户ID"; }
      ;;
    409)
      EXISTS=$((EXISTS + 1))
      existed=1
      # 决策 D11: 提取原第 6 列的密码部分,写列时原样保留(密码只回显一次,不可找回)
      old_pw="$(extract_pw_part "$c6")"
      # 已存在 → 查用户拿 id(q 为模糊查询,按 username 精确过滤)
      api_get_q "/users" "q" "$acct"
      if [ "$API_CODE" = "200" ]; then
        user_id="$(extract_match "id" "username" "$acct")"
      fi
      if [ -z "$user_id" ]; then
        # 查不到用户 ID → 加组无法进行,按加组失败合成(D11: 有密码部分仍保留密码)
        gfail="加组失败:查用户ID失败(HTTP $API_CODE)"
      fi
      ;;
    000)
      CFAIL=$((CFAIL + 1)); note="失败:建号 网络错误" ;;
    *)
      CFAIL=$((CFAIL + 1)); note="失败:建号 HTTP $API_CODE" ;;
  esac

  # 2b) 加组: 角色列即组名;409(已在组中)视为成功
  if [ -n "$user_id" ]; then
    gid="$(resolve_group "$role")" || gid=""
    if [ -n "$gid" ]; then
      api_call "POST" "/groups/$gid/members" "$(printf '{"user_id":"%s"}' "$user_id")"
      case "$API_CODE" in
        2??|409) : ;;   # 409 = 已在组中,幂等成功
        *)
          GFAIL=$((GFAIL + 1))
          gfail="加组失败:加成员 HTTP $API_CODE" ;;
      esac
    else
      GFAIL=$((GFAIL + 1))
      gfail="加组失败:${GF_ERR:-组解析失败}"
    fi
  fi

  # 2c) 第 6 列状态(决策 D5/D11): 成功=密码;建号成功+加组失败=密码|加组失败:...
  #     已存在(409)=有密码部分则保留(补组成功清除历史失败态,失败追加本次原因);
  #     无密码部分=已存在,补加组 / 已存在|加组失败:<原因>;建号失败=状态文本
  if [ -n "$pw" ]; then
    col6new="$pw"
    [ -n "$gfail" ] && col6new="$pw|$gfail"
  elif [ -n "$note" ]; then
    col6new="$note"
    [ -n "$gfail" ] && col6new="$note,$gfail"
  elif [ -n "$existed" ]; then
    if [ -n "$old_pw" ]; then
      col6new="$old_pw"
      [ -n "$gfail" ] && col6new="$old_pw|$gfail"
    else
      col6new="已存在,补加组"
      [ -n "$gfail" ] && col6new="已存在|${gfail}"
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s%s' "$o1" "$o2" "$o3" "$o4" "$o5" "$col6new" "$EOL" >> "$OUT_TMP"
  CHANGED=1
  log "行$linenum $name($acct) 组[$role] -> $col6new"
  case "$col6new" in
    *失败*)
      printf '行%s %s(%s): %s\n' "$linenum" "$name" "$acct" "$col6new" >> "$FAILED_LIST" ;;
  esac
done < "$PLAN"

# ─── 写回(先备份,后原子替换)────────────────────────────────────────────────
if [ "$CHANGED" = "1" ]; then
  cp -p "$CSV" "$CSV.bak" || { err "备份 $CSV.bak 失败,放弃写回(结果在 $OUT_TMP)"; exit 1; }
  mv -f "$OUT_TMP" "$CSV" || { err "写回失败(结果保留在 $OUT_TMP)"; exit 1; }
  OUT_TMP=""
  log "已写回 $CSV(原文件备份为 $CSV.bak)"
else
  rm -f "$OUT_TMP"; OUT_TMP=""
  log "无任何改动,未写回 csv。"
fi

# ─── 运行摘要 ────────────────────────────────────────────────────────────────
log "──────── 统计摘要 ────────"
log "建号成功=$CREATED  已存在,补加组=$EXISTS"
log "已有结果跳过=$SKIP_DONE  运营为空=$SKIP_OP_N  账号为空=$SKIP_ACC_N  角色为空=$SKIP_ROLE_N  全空行保留=$EMPTY_N"
log "失败:建号=$CFAIL  加组失败=$GFAIL"
if [ -s "$FAILED_LIST" ]; then
  log "---- 失败行清单 ----"
  cat "$FAILED_LIST"
else
  log "失败行清单: (无)"
fi
exit 0
