#!/usr/bin/env bash
set -euo pipefail
umask 077

# Antigravity 额度导出（2026-11-08 起）：不再走本地 RPC 进程发现，与 app 的
# AntigravityFetcher 同路径——读登录钥匙串凭据（service=gemini / account=antigravity）
# 并直接请求 Google Cloud Code 远端配额接口。Antigravity / agy 无需运行。

output_path="${1:-}"

# --- 1. 读钥匙串凭据 -----------------------------------------------------------
credential="$(/usr/bin/security find-generic-password -s gemini -a antigravity -w 2>/dev/null || true)"
if [[ -z "${credential}" ]]; then
  echo "未读取到 Antigravity 登录凭据，请打开 Antigravity 并完成登录" >&2
  exit 1
fi

# --- 2. 解析凭据并本地判过期（过期时不发任何网络请求） -----------------------------
# 凭据值形如 go-keyring-base64:<base64(JSON)>，JSON 内取 token.{access_token, expiry}。
# 凭据原文经环境变量传给 python（避免出现在 argv / ps），python 只向 stdout 输出
# access_token；结构不合法或已过期时写 stderr 并以非零退出。
access_token="$(ANTIGRAVITY_CREDENTIAL="${credential}" /usr/bin/python3 - <<'PY'
import base64
import binascii
import json
import os
import re
import sys
from datetime import datetime, timezone

raw = os.environ.get("ANTIGRAVITY_CREDENTIAL", "")
prefix = "go-keyring-base64:"
if not raw.startswith(prefix):
    print("Antigravity 凭据格式无法识别（缺少 go-keyring-base64: 前缀）", file=sys.stderr)
    sys.exit(1)

encoded = raw[len(prefix):].strip()
padded = encoded + "=" * (-len(encoded) % 4)
try:
    payload = base64.b64decode(padded)
except (binascii.Error, ValueError):
    try:
        payload = base64.urlsafe_b64decode(padded)
    except (binascii.Error, ValueError):
        print("Antigravity 凭据 base64 解码失败", file=sys.stderr)
        sys.exit(1)
try:
    obj = json.loads(payload.decode("utf-8"))
except (ValueError, UnicodeDecodeError):
    print("Antigravity 凭据 JSON 解析失败", file=sys.stderr)
    sys.exit(1)

token = obj.get("token") or {}
access_token = str(token.get("access_token") or "").strip()
expiry_raw = str(token.get("expiry") or "").strip()
if not access_token or not expiry_raw:
    print("Antigravity 凭据缺少 access_token / expiry，请打开 Antigravity 更新凭据", file=sys.stderr)
    sys.exit(1)

# expiry 为 ISO8601 带时区（Go RFC3339Nano 可能带 1–9 位小数秒）；
# fromisoformat 只认 3/6 位小数，统一去掉小数部分（秒级精度足够过期判定）。
text = re.sub(r"\.\d+", "", expiry_raw)
if text.endswith(("Z", "z")):
    text = text[:-1] + "+00:00"
try:
    expiry = datetime.fromisoformat(text)
except ValueError:
    print("Antigravity 凭据 expiry 无法解析，请打开 Antigravity 更新凭据", file=sys.stderr)
    sys.exit(1)
if expiry.tzinfo is None:
    print("Antigravity 凭据 expiry 缺少时区，请打开 Antigravity 更新凭据", file=sys.stderr)
    sys.exit(1)

if datetime.now(timezone.utc) >= expiry:
    print("token 已过期：在 Antigravity 中发起一次对话即可刷新凭据", file=sys.stderr)
    sys.exit(1)

print(access_token)
PY
)"

# --- 3. hub 身份 UA：版本取 Antigravity.app 的 CFBundleShortVersionString --------
# 读不到回退 2.26.0（与 AntigravityFetcher.fallbackHubVersion 一致）。
hub_version="$(/usr/bin/defaults read /Applications/Antigravity.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || true)"
hub_version="${hub_version//[[:space:]]/}"
if [[ -z "${hub_version}" ]]; then
  hub_version="2.26.0"
fi

# --- 4. 请求远端配额接口（主机回退：daily → cloudcode-pa → sandbox） ---------------
# 仅 401 终止（凭据无效）；其余非 2xx 与传输失败换下一主机，全部失败报最后一台。
# access_token 经 stdin 喂给 curl 的 -H @-，不出现在 argv / ps。
hosts=(
  "daily-cloudcode-pa.googleapis.com"
  "cloudcode-pa.googleapis.com"
  "daily-cloudcode-pa.sandbox.googleapis.com"
)

quota_json=""
last_error=""
for host in "${hosts[@]}"; do
  response="$(
    /usr/bin/curl --silent --show-error \
      --connect-timeout 2 --max-time 15 \
      -X POST "https://${host}/v1internal:retrieveUserQuotaSummary" \
      -H 'Content-Type: application/json' \
      -H "User-Agent: antigravity/hub/${hub_version} (aidev_client; os_type=darwin; arch=arm64)" \
      -H @- \
      --data '{}' \
      --write-out '\n%{http_code}' \
      <<<"Authorization: Bearer ${access_token}" || true
  )"
  http_code="${response##*$'\n'}"
  if [[ "${http_code}" =~ ^2[0-9]{2}$ ]]; then
    quota_json="${response%$'\n'*}"
    break
  fi
  if [[ "${http_code}" == "401" ]]; then
    echo "token 已过期：在 Antigravity 中发起一次对话即可刷新凭据" >&2
    exit 1
  fi
  if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
    last_error="${host}（无 HTTP 响应）"
  else
    last_error="${host}（HTTP ${http_code}）"
  fi
done

if [[ -z "${quota_json}" ]]; then
  echo "Antigravity 配额接口请求失败（最后一个主机：${last_error}）" >&2
  exit 1
fi

# --- 5. 输出：带路径参数时原子落盘（0600），否则打印到 stdout -----------------------
if [[ -n "${output_path}" ]]; then
  output_dir="$(/usr/bin/dirname "${output_path}")"
  /bin/mkdir -p "${output_dir}"
  temp_output="$(mktemp "${output_dir}/.antigravity-quota.XXXXXX")"
  cleanup() {
    rm -f "${temp_output}"
  }
  trap cleanup EXIT
  printf '%s\n' "${quota_json}" > "${temp_output}"
  /bin/chmod 600 "${temp_output}"
  /bin/mv -f "${temp_output}" "${output_path}"
  trap - EXIT
  echo "已写入 ${output_path}"
else
  printf '%s\n' "${quota_json}"
fi
