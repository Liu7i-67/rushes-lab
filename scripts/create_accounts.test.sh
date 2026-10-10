#!/usr/bin/env bash
# =============================================================================
# create_accounts.test.sh — 批量创建账号脚本 dry-run 黑盒断言测试
#
# 被测对象:与本脚本同目录的 create_accounts.sh
#   用法被测形态: bash create_accounts.sh <csv> --dry-run
#   契约依据:docs/qdev/2026-10-09-account-batch-create.md(功能点 1/2/7 与 D2/D5/D6/D7/D10)
#
# 范围:仅 dry-run——不登录、不发任何 HTTP、不写被测 csv。
#       dev/prod 实跑与幂等/失败路径用例见
#       docs/qdev/2026-10-09-account-batch-create-testcases.md
#
# 运行:bash scripts/create_accounts.test.sh
# 退出码:0 = 全部断言通过;1 = 存在 FAIL;2 = 被测脚本不存在(环境错误,非用例失败)
#
# 内嵌小样 csv(表头 + 12 行数据,UTF-8 BOM + CRLF)预期执行计划:
#   行2  创建 自然流一部_钱程似锦组_张三  组长      15500000001
#   行3  创建 自然流一部_钱程似锦组_李四  运营      15500000002   (同行前向填充)
#   行4  全空,原样保留
#   行5  创建 自然流一部_开心赚钱组_王五  组长      15500000003   (部门跨全空行继承)
#   行6  跳过:运营为空 (有账号,继承 自然流一部_开心赚钱组)  15500000004
#   行7  创建 自然流一部_扶摇直上_赵六    运营助理  15500000005   (组别新段)
#   行8  跳过:角色为空 (继承 自然流一部_扶摇直上_钱七)      15500000006
#   行9  跳过:账号为空 (自然流一部_黄金矿工_孙八;兼验 CRLF:\r 不得混入第5列)
#   行10 全空,原样保留
#   行11 创建 IP部_發财致富_周九         组长      15500000007   (部门重置)
#   行12 跳过:运营为空 (继承 IP部_發财致富)               15500000008
#   行13 跳过:账号为空 (IP部_發财致富_吴十)
#   合计:数据行 12 = 待创建 5 + 运营空 2 + 账号空 2 + 角色空 1 + 全空 2
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/create_accounts.sh"

if [ ! -f "$TARGET" ]; then
  echo "环境错误: 被测脚本不存在: $TARGET" >&2
  echo "(本测试只含断言,不产出被测脚本;请先实现 scripts/create_accounts.sh)" >&2
  exit 2
fi

pass=0 fail=0 warn=0
ok()   { printf 'PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'WARN  %s\n' "$*"; warn=$((warn+1)); }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
CSV="$WORK/sample.csv"
OUT="$WORK/out.txt"

# ---- 内嵌小样 csv:UTF-8 BOM + CRLF,表头 + 12 行数据(内容即上方注释表) ----
{
  printf '\xef\xbb\xbf'
  printf '部门,组别,运营,角色,账号\r\n'
  printf '自然流一部,钱程似锦组,张三,组长,15500000001\r\n'
  printf ',,李四,运营,15500000002\r\n'
  printf ',,,,,\r\n'
  printf ',开心赚钱组,王五,组长,15500000003\r\n'
  printf ',,,运营,15500000004\r\n'
  printf ',扶摇直上,赵六,运营助理,15500000005\r\n'
  printf ',,钱七,,15500000006\r\n'
  printf ',黄金矿工,孙八,运营,\r\n'
  printf ',,,,,\r\n'
  printf 'IP部,發财致富,周九,组长,15500000007\r\n'
  printf ',,,运营,15500000008\r\n'
  printf ',,吴十,运营,\r\n'
} > "$CSV"

MD5_BEFORE="$(md5sum "$CSV" | awk '{print $1}')"

# 无凭证 dry-run:双 unset 凭证环境变量;stdin 接 /dev/null——
# 若实现误在 dry-run 交互索要凭证,应立即 EOF 报错退出而非挂起。
env -u ADMIN_USER -u ADMIN_PASS bash "$TARGET" "$CSV" --dry-run >"$OUT" 2>&1 </dev/null
RC=$?

echo "== 被测: $TARGET"
echo "== 被测 csv: $CSV(内嵌小样,BOM+CRLF,数据行 12)"
echo "== dry-run 退出码: $RC"
echo

# ---- 通用断言辅助 ----
has()            { grep -qF -- "$1" "$OUT"; }
count_of()       { grep -oF -- "$1" "$OUT" | wc -l | tr -d '[:space:]'; }
first_line_of()  { grep -F -- "$1" "$OUT" 2>/dev/null | head -n 1; }

# line_check <描述> <行锚点> <该行必含> [该行禁含]
line_check() {
  local desc="$1" anchor="$2" want="$3" forbid="${4:-}" l msg="" good=1
  l="$(first_line_of "$anchor")"
  if [ -z "$l" ]; then
    bad "$desc(输出中未找到锚点「$anchor」)"
    return
  fi
  if [ -n "$want" ]; then
    case "$l" in *"$want"*) ;; *) good=0; msg="缺少「$want」";; esac
  fi
  if [ -n "$forbid" ]; then
    case "$l" in *"$forbid"*) good=0; msg="${msg:+$msg; }含「$forbid」";; esac
  fi
  if [ "$good" -eq 1 ]; then ok "$desc"; else bad "$desc($msg; 该行: $l)"; fi
}

# ---- T01 无凭证可运行 ----
if [ "$RC" -eq 0 ]; then
  ok "T01 无 ADMIN_USER/ADMIN_PASS 时 dry-run 退出码 0(dry-run 不要求登录)"
else
  bad "T01 无凭证 dry-run 退出码=$RC(预期 0;dry-run 不得登录/索要凭证)"
fi

# ---- T02/T03 dry-run 副作用为零 ----
MD5_AFTER="$(md5sum "$CSV" | awk '{print $1}')"
if [ -n "$MD5_BEFORE" ] && [ "$MD5_BEFORE" = "$MD5_AFTER" ]; then
  ok "T02 dry-run 不修改被测 csv(md5 前后一致)"
else
  bad "T02 被测 csv 被修改(md5 前=$MD5_BEFORE 后=$MD5_AFTER)"
fi
if [ ! -e "$CSV.bak" ]; then
  ok "T03 dry-run 不生成 .bak 备份"
else
  bad "T03 dry-run 生成了 $CSV.bak(备份只应在实跑写回前产生)"
fi

# ---- T04 BOM/表头识别 ----
# 表头被当数据行的特征:同一行既出现表头拼出的姓名「部门_组别_运营」又出现其登录名「账号」。
# 不能只查姓名串——计划表列标题(如「姓名(部门_组别_运营)」)会合法地含它。
if grep -q '部门_组别_运营.*账号' "$OUT"; then
  bad "T04 表头被当作数据行(存在含「部门_组别_运营」且登录名为「账号」的行,疑似 BOM 未剥离/表头未跳过)"
else
  ok "T04 BOM 剥离且首行表头被跳过(无表头数据行)"
fi

# ---- T05-T09 姓名拼接(部门_组别_运营,前向填充) ----
line_check "T05 行2 基线姓名:自然流一部_钱程似锦组_张三" '15500000001' '自然流一部_钱程似锦组_张三'
line_check "T06 行3 同行前向填充:自然流一部_钱程似锦组_李四" '15500000002' '自然流一部_钱程似锦组_李四'
line_check "T07 行5 部门跨全空行(行4)继承:自然流一部_开心赚钱组_王五" '15500000003' '自然流一部_开心赚钱组_王五'
line_check "T08 行7 部门继续继承+组别新段:自然流一部_扶摇直上_赵六" '15500000005' '自然流一部_扶摇直上_赵六'
line_check "T09 行11 部门重置:IP部_發财致富_周九" '15500000007' 'IP部_發财致富_周九'

# ---- T10-T12 待创建行:角色组入计划、无跳过状态 ----
line_check "T10 行2 待创建,角色组=组长"   '15500000001' '组长'   '跳过'
line_check "T11 行3 待创建,角色组=运营"   '15500000002' '运营'   '跳过'
line_check "T12 行7 待创建,角色组=运营助理" '15500000005' '运营助理' '跳过'

# ---- T13-T17 跳过原因逐行核对(状态文本,半角冒号,按需求文档原文) ----
line_check "T13 行6 运营空跳过(该行有账号,验证判定顺序运营先于账号)" '15500000004' '跳过:运营为空'
line_check "T14 行12 运营空跳过(IP部段继承)" '15500000008' '跳过:运营为空'
line_check "T15 行9 账号空跳过(兼验 CRLF:尾随\\r 不得混入账号列)" '孙八' '跳过:账号为空'
line_check "T16 行13 账号空跳过" '吴十' '跳过:账号为空'
line_check "T17 行8 角色空跳过(D2:整行跳过,该行有账号)" '15500000006' '跳过:角色为空'

# ---- T18-T20 各跳过类计数(只数计划行;排除摘要的「状态=数量」键值复述行) ----
count_plan_status() { # $1=状态文本 → 含该状态且非键值行(无 =)的行数
  grep -F -- "$1" "$OUT" | grep -vF -- '=' | wc -l | tr -d '[:space:]'
}
c="$(count_plan_status '跳过:运营为空')"
if [ "$c" -eq 2 ]; then ok "T18 计划行「跳过:运营为空」=2"; else bad "T18 计划行「跳过:运营为空」=$c(预期 2)"; fi
c="$(count_plan_status '跳过:账号为空')"
if [ "$c" -eq 2 ]; then ok "T19 计划行「跳过:账号为空」=2"; else bad "T19 计划行「跳过:账号为空」=$c(预期 2)"; fi
c="$(count_plan_status '跳过:角色为空')"
if [ "$c" -eq 1 ]; then ok "T20 计划行「跳过:角色为空」=1"; else bad "T20 计划行「跳过:角色为空」=$c(预期 1)"; fi

# ---- T21 待创建计划行数 ----
created_found=0
for p in 15500000001 15500000002 15500000003 15500000005 15500000007; do
  l="$(first_line_of "$p")"
  if [ -n "$l" ] && ! printf '%s' "$l" | grep -qF '跳过'; then
    created_found=$((created_found+1))
  fi
done
if [ "$created_found" -eq 5 ]; then
  ok "T21 待创建计划行数=5"
else
  bad "T21 待创建计划行数=$created_found(预期 5;数据行 12 − 全空 2 − 跳过 5)"
fi

# ---- T22 计划行覆盖(总数据行 12 − 全空 2 = 10 行全部入计划) ----
covered=0
for a in 15500000001 15500000002 15500000003 15500000004 15500000005 \
         15500000006 15500000007 15500000008 孙八 吴十; do
  [ -n "$(first_line_of "$a")" ] && covered=$((covered+1))
done
if [ "$covered" -eq 10 ]; then
  ok "T22 计划覆盖全部非全空行(10/10;总数据行 12,全空 2 行原样保留不计划)"
else
  bad "T22 计划行覆盖=$covered/10(每个非全空数据行都应出现在计划中)"
fi

# ---- T23 每个登录名在计划中恰好出现一次 ----
dup_bad=0
for p in 15500000001 15500000002 15500000003 15500000004 15500000005 15500000006 15500000007 15500000008; do
  c="$(count_of "$p")"
  if [ "$c" -ne 1 ]; then
    dup_bad=1
    echo "      … $p 在输出中出现 $c 次(预期 1)"
  fi
done
if [ "$dup_bad" -eq 0 ]; then
  ok "T23 每个登录名在计划中恰好出现一次(无重复/无遗漏)"
else
  bad "T23 存在出现次数≠1 的登录名(见上方明细)"
fi

# ---- T24 运行摘要数值(软断言) ----
# 需求未钉死摘要格式:识别得到数值则必须与推算一致;识别不到仅 WARN 不判 FAIL
# (计划级硬计数已由 T18-T23 覆盖)。格式定稿后可改为硬断言。
# 模式说明:(交替)需显式分组;[^0-9|] 防止跨列匹配到下一行的行号/手机号。
getnum() { # $1=关键词(支持 | 交替) → 关键词后最近的数字,无则空
  grep -oE "($1)[^0-9|]{0,12}[0-9]+" "$OUT" 2>/dev/null | head -n 1 | grep -oE '[0-9]+$'
}
check_num() { # <描述> <关键词> <预期>
  local v; v="$(getnum "$2")"
  if [ -z "$v" ]; then
    note "$1(输出未识别到「$2」后接数值,跳过;由 T18-T23 兜底)"
  elif [ "$v" -eq "$3" ]; then
    ok "$1"
  else
    bad "$1(实际=$v 预期=$3)"
  fi
}
check_num "T24a 摘要:总数据行" '总行|数据行|总数据' 12
check_num "T24b 摘要:待创建"   '待创建|创建数'      5
# 跳过合计 = 三类之和(摘要可能只给分类值不给合计;兼容「运营为空」/「运营空」两种写法)
s1="$(getnum '运营为?空')"; s2="$(getnum '账号为?空')"; s3="$(getnum '角色为?空')"
if [ -n "$s1" ] && [ -n "$s2" ] && [ -n "$s3" ]; then
  if [ $((s1+s2+s3)) -eq 5 ]; then
    ok "T24c 摘要:跳过分类合计=5($s1+$s2+$s3)"
  else
    bad "T24c 摘要:跳过分类合计=$(($s1+$s2+$s3))(预期 5;$s1+$s2+$s3)"
  fi
else
  note "T24c 摘要:输出未识别到跳过分类数值,跳过;由 T18-T20 兜底"
fi

# ---- 汇总 ----
echo
echo "==============================================="
echo "断言总计: $((pass+fail))  通过=$pass  失败=$fail  提示=$warn"
if [ "$fail" -gt 0 ]; then
  echo "---- 被测脚本输出(前 60 行,供排障) ----"
  sed -n '1,60p' "$OUT"
  echo "-----------------------------------------------"
  echo "结果: FAILED"
  exit 1
fi
echo "结果: ALL PASS"
exit 0
