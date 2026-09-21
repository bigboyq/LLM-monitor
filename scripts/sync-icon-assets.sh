#!/usr/bin/env bash
# scripts/sync-icon-assets.sh
# 图标资产唯一同步入口：把「源资产」同步到所有打包副本，并提供 --check 只读校验。
#
# 同步范围（本脚本覆盖）：
#   (a) Assets/icon-master.png           → Sources/LLM-monitor/Resources/IconPreview/icon-master.png
#   (b) images/llm-quota-730-2-dark.svg  → Sources/LLM-monitor/Resources/IconPreview/llm-quota-730-2-dark.svg
#       （SwiftPM .copy 资源要求文件位于 Sources 内，这两份副本结构性无法消除）
#   (c) 调用 scripts/generate-icns.sh 从 master png 重生成回退图标
#       Sources/LLM-monitor/Resources/AppIcon.icns（供无 Icon Composer 支持的旧 macOS 用）
#   (d) 写 sidecar Assets/AppIcon.icns.source.sha256（sha256sum 兼容格式），记录
#       「当前 icns 由哪个版本的 master png 生成」——sidecar 哈希 == 当前 master 哈希
#       即 icns 新鲜度的确定性判据（跨机器稳定，不用 mtime）。
#
# 剩余的手工清单（本脚本有意不覆盖）：
#   1. Icon Composer 工程 images/LLMMenu.icon 是主打包路线（Assets.car）的源，
#      GUI 维护、不自动化：换图标后需在 Icon Composer 里手工更新并导出。
#   2. 若菜单栏 quotaLogo 几何也要变，需改 QuotaLogoSVGBuilder 并跑一致性测试。
#   3. spec/ 文档中图标相关描述需人工同步。
#   images/ 下的 light 变体与 dark.png 是设计存档，不在同步范围。
#
# 幂等性：一切已同步时运行本脚本不产生任何变化（cp 前先 cmp、sidecar 内容
# 不变则不重写；icns 在同机同工具链下重生成逐字节一致）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

MASTER_PNG="$ROOT_DIR/Assets/icon-master.png"
DESIGN_SVG="$ROOT_DIR/images/llm-quota-730-2-dark.svg"
PREVIEW_DIR="$ROOT_DIR/Sources/LLM-monitor/Resources/IconPreview"
PREVIEW_PNG="$PREVIEW_DIR/icon-master.png"
PREVIEW_SVG="$PREVIEW_DIR/llm-quota-730-2-dark.svg"
ICNS_OUT_DIR="$ROOT_DIR/Sources/LLM-monitor/Resources"
ICNS="$ICNS_OUT_DIR/AppIcon.icns"
SIDECAR="$ROOT_DIR/Assets/AppIcon.icns.source.sha256"
GENERATE_ICNS="$ROOT_DIR/scripts/generate-icns.sh"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
elif [ "$#" -gt 0 ]; then
    echo "Usage: $0 [--check]"
    echo "  无参数   执行同步（cp 副本 + 重生成 icns + 写 sidecar）"
    echo "  --check  只校验不写任何文件；存在 drift 时 exit 1 并逐项指出"
    exit 1
fi

# 源资产缺失属于仓库结构损坏，同步/校验都无法继续（区别于副本 drift）。
for src in "$MASTER_PNG" "$DESIGN_SVG" "$GENERATE_ICNS"; do
    if [ ! -f "$src" ]; then
        echo "ERROR: 源资产缺失: $src" >&2
        exit 1
    fi
done

master_sha() {
    shasum -a 256 "$MASTER_PNG" | awk '{print $1}'
}

# sidecar 为 sha256sum 兼容格式：<sha256>␣␣<相对仓库根的源路径>。
# 内容不变则不重写，避免无意义的 mtime 变化。
write_sidecar() {
    local content="${1}  Assets/icon-master.png"
    if [ ! -f "$SIDECAR" ] || [ "$(cat "$SIDECAR")" != "$content" ]; then
        printf '%s\n' "$content" > "$SIDECAR"
        echo "==> Updated $SIDECAR"
    fi
}

# 内容一致时跳过 cp，减少不必要的 mtime / 增量构建扰动。
copy_if_changed() {
    local src="$1" dst="$2"
    if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
        cp "$src" "$dst"
        echo "==> Synced ${dst#"$ROOT_DIR"/}"
    fi
}

# 校验逻辑与同步结束后的自检共用；返回失败项数量（0 = 全部一致）。
# 逐字节比较用 cmp -s，sidecar 新鲜度用 shasum -a 256（跨机器稳定的判据，不用 mtime）。
run_checks() {
    local failed=0
    local rel_master="Assets/icon-master.png"
    local rel_svg="images/llm-quota-730-2-dark.svg"

    if [ ! -f "$PREVIEW_PNG" ] || ! cmp -s "$MASTER_PNG" "$PREVIEW_PNG"; then
        echo "DRIFT: $rel_master 与 Sources/LLM-monitor/Resources/IconPreview/icon-master.png 不逐字节一致（或副本缺失）"
        failed=$((failed + 1))
    fi
    if [ ! -f "$PREVIEW_SVG" ] || ! cmp -s "$DESIGN_SVG" "$PREVIEW_SVG"; then
        echo "DRIFT: $rel_svg 与 Sources/LLM-monitor/Resources/IconPreview/llm-quota-730-2-dark.svg 不逐字节一致（或副本缺失）"
        failed=$((failed + 1))
    fi
    if [ ! -f "$ICNS" ]; then
        echo "DRIFT: Sources/LLM-monitor/Resources/AppIcon.icns 不存在"
        failed=$((failed + 1))
    fi
    if [ ! -f "$SIDECAR" ]; then
        echo "DRIFT: Assets/AppIcon.icns.source.sha256 不存在，icns 新鲜度无从判定"
        failed=$((failed + 1))
    else
        local recorded current
        recorded="$(awk '{print $1}' "$SIDECAR")"
        current="$(master_sha)"
        if [ "$recorded" != "$current" ]; then
            echo "DRIFT: AppIcon.icns 已过期 —— sidecar 记录的 master sha256 ($recorded) != 当前 $rel_master 的 sha256 ($current)"
            failed=$((failed + 1))
        fi
    fi

    if [ "$failed" -gt 0 ]; then
        echo "修复: 运行 ./scripts/sync-icon-assets.sh 重新同步（并提交同步产物）"
    fi
    return "$failed"
}

if [ "$CHECK_ONLY" = "1" ]; then
    if run_checks; then
        echo "✓ 图标资产已同步（副本一致 / icns 新鲜度匹配）"
    else
        exit 1
    fi
else
    echo "==> Syncing icon assets..."
    copy_if_changed "$MASTER_PNG" "$PREVIEW_PNG"
    copy_if_changed "$DESIGN_SVG" "$PREVIEW_SVG"
    # 回退 icns 每次都从 master png 重生成：同机同工具链下逐字节可复现，
    # 无条件重生成可兜住「icns 被陈旧版本手工覆盖但 sidecar 巧合一致」的情况。
    "$GENERATE_ICNS" "$ICNS_OUT_DIR"
    write_sidecar "$(master_sha)"

    # 同步结束后的自检与 --check 共用同一套判定，防止「同步即静默」。
    if run_checks; then
        echo "✓ 图标资产已同步（副本一致 / icns 新鲜度匹配）"
    else
        echo "ERROR: 同步后自检仍未通过，请检查上方 DRIFT 项" >&2
        exit 1
    fi
fi
