#!/usr/bin/env bash
# scripts/sync-holiday-data.sh
# 法定节假日快照资源唯一同步入口：拉取上游 chinese-days JSON，抽取
# 「法定节假日 ∪ 调休放假日」的日期并集，产出
# Sources/LLM-monitor/Resources/ChinaHolidays.json（随 app 打包的静态离线快照，
# 供 Models/HolidayCalendar.swift 加载）。
#
# 上游：https://cdn.jsdelivr.net/npm/chinese-days/dist/chinese-days.json
#   （npm 包 chinese-days，单层 JSON：顶层三键 holidays / workdays / inLieuDays，
#   每键为 "YYYY-MM-DD": "English,中文,数字旗标" 的扁平映射，覆盖 2004–2026。）
#
# Rule A 决策（高峰判定的工作日口径，与 DeepSeek 统一形状）：
#   工作日 = 周一–周五 ∧ 当天不是法定节假日。因此快照抽取的"非高峰日集合"
#   = holidays ∪ inLieuDays —— inLieuDays 是调休换来的放假日（常为周一–周五），
#   必须并入；workdays（调休上班的周六/周日）**有意丢弃不建模**：它们本来就不
#   满足"周一–周五"，Rule A 下天然不算高峰，无需"调休上班日算高峰"的例外规则。
#
# 年份取舍：只保留 [当前年-1, …] 起的数据。历史年份对高峰判定无价值（计价路径
# 回看样本日期最多约 30 天）；保留上一年是为了跨年样本（1 月初回看的样本日期
# 会落在上一年 12 月）。跨年后输出自然变化属预期，重跑本脚本即可。
#
# --check 语义：重新生成期望内容并与现存资源比对，只比对 source 与 holidays。
# fetchedAt 是「上次同步日期」的元信息戳，随日历日自然漂移，不参与比对——
# 静态快照不应要求每天重新同步；holidays 数组本身依赖当前年份过滤，跨年 drift
# 同样以重跑本脚本消除。
#
# 幂等性：同一天重复运行且上游内容不变时，产出逐字节一致；与现存文件 cmp
# 一致则不覆盖，避免无意义的 mtime / 增量构建扰动。
#
# 日期合法性分工：本脚本只做格式/取值范围护栏（真日期的严格校验——如
# 2026-02-30 这类归一化伪日期——由 HolidayCalendarTests 的 Swift 侧
# Calendar round-trip 守门，跨平台确定）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_URL="https://cdn.jsdelivr.net/npm/chinese-days/dist/chinese-days.json"
OUT="$ROOT_DIR/Sources/LLM-monitor/Resources/ChinaHolidays.json"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 需要 jq（macOS: brew install jq）" >&2
    exit 1
fi

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
elif [ "$#" -gt 0 ]; then
    echo "Usage: $0 [--check]"
    echo "  无参数   拉取上游并重生成 ChinaHolidays.json（内容不变则不写）"
    echo "  --check  只校验不写文件；存在 drift 时 exit 1"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "$UPSTREAM_URL" -o "$WORK/upstream.json"

# 结构护栏：顶层必须是 holidays / workdays / inLieuDays 三个对象键。上游 schema
# 变化时停下来人工确认，不要静默产出错误快照。
for key in holidays workdays inLieuDays; do
    if ! jq -e "has(\"${key}\") and (.\"${key}\" | type == \"object\")" "$WORK/upstream.json" >/dev/null; then
        echo "ERROR: 上游 JSON 结构不符预期：缺少顶层对象键 \"$key\"，schema 可能已变化，请人工核对 $UPSTREAM_URL" >&2
        exit 1
    fi
done

# 抽取 holidays ∪ inLieuDays 的日期键并集；workdays 有意丢弃（Rule A，见文件头）。
# unique 即排序+去重；年份过滤 [当前年-1, …]。资源格式：
#   {"source": <上游 URL>, "fetchedAt": "YYYY-MM-DD", "holidays": ["YYYY-MM-DD", ...]}
jq --arg url "$UPSTREAM_URL" '{
    source: $url,
    fetchedAt: (now | strftime("%Y-%m-%d")),
    holidays: (
        [(.holidays | keys[]), (.inLieuDays | keys[])]
        | unique
        | map(select((.[0:4] | tonumber) >= (now | strftime("%Y") | tonumber) - 1))
    )
}' "$WORK/upstream.json" > "$WORK/china-holidays.json"

# 产出护栏：source / fetchedAt 非空字符串，holidays 非空数组，元素均为
# YYYY-MM-DD 格式且月/日在取值范围内（真日期校验归 Swift 测试，见文件头）。
if ! jq -e '
    (.source | type == "string" and length > 0)
    and (.fetchedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.holidays | type == "array" and length > 0)
    and (.holidays | all(
        .[]; test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        and ((.[5:7] | tonumber) >= 1 and (.[5:7] | tonumber) <= 12)
        and ((.[8:10] | tonumber) >= 1 and (.[8:10] | tonumber) <= 31)
    ))
' "$WORK/china-holidays.json" >/dev/null; then
    echo "ERROR: 生成的快照未通过格式护栏（source/fetchedAt 为空、holidays 为空或日期格式非法），请人工核对上游数据" >&2
    exit 1
fi

if [ "$CHECK_ONLY" = "1" ]; then
    if [ ! -f "$OUT" ]; then
        echo "DRIFT: ${OUT#"$ROOT_DIR"/} 不存在，请运行 ./scripts/sync-holiday-data.sh 生成"
        exit 1
    fi
    # fetchedAt 不参与比对（--check 语义见文件头）
    if ! diff <(jq -S 'del(.fetchedAt)' "$WORK/china-holidays.json") \
              <(jq -S 'del(.fetchedAt)' "$OUT") >/dev/null; then
        echo "DRIFT: ${OUT#"$ROOT_DIR"/} 与上游期望内容（source / holidays）不一致，请运行 ./scripts/sync-holiday-data.sh 重新同步"
        exit 1
    fi
    echo "✓ 节假日快照已同步（source / holidays 与上游一致，$(jq -r '.holidays | length' "$OUT") 天）"
else
    if [ -f "$OUT" ] && cmp -s "$WORK/china-holidays.json" "$OUT"; then
        echo "✓ 节假日快照无变化（${OUT#"$ROOT_DIR"/}，$(jq -r '.holidays | length' "$OUT") 天）"
    else
        mv "$WORK/china-holidays.json" "$OUT"
        echo "==> Synced ${OUT#"$ROOT_DIR"/}（holidays=$(jq -r '.holidays | length' "$OUT") 天，fetchedAt=$(jq -r '.fetchedAt' "$OUT")）"
    fi
fi
