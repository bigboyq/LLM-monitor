#!/usr/bin/env bash
set -euo pipefail
umask 077

output_path="${1:-}"

pgrep_output="$(/usr/bin/pgrep -fal '(^|/)(language_server|language_server_[^ ]+)( |$)' || true)"
# Antigravity IDE.app 已剥离支持：其 bundle 路径、--app_data_dir antigravity-ide
# 或专属的带后缀二进制命中的 language_server 进程不参与候选选择。
pgrep_output="$(printf '%s\n' "${pgrep_output}" | /usr/bin/grep -Eiv 'antigravity ide\.app|antigravity-ide|(^|/)language[-_]server(_[a-z0-9]+)+' || true)"
if [[ -z "${pgrep_output}" ]]; then
  echo "未发现运行中的 Antigravity language_server，请先启动 Antigravity 并完成登录" >&2
  exit 1
fi

selected_line="$(printf '%s\n' "${pgrep_output}" | /usr/bin/grep -E '(^|/)(language_server|language_server_[^ ]+)( |$)' | /usr/bin/grep -- '--csrf_token' | /usr/bin/head -n 1 || true)"
if [[ -z "${selected_line}" ]]; then
  selected_line="$(printf '%s\n' "${pgrep_output}" | /usr/bin/grep -E '(^|/)(language_server|language_server_[^ ]+)( |$)' | /usr/bin/head -n 1 || true)"
fi
if [[ -z "${selected_line}" ]]; then
  echo "未发现命令路径合法的 Antigravity language_server" >&2
  exit 1
fi

pid="${selected_line%% *}"
command_line="${selected_line#* }"
csrf_token="$(printf '%s\n' "${command_line}" | /usr/bin/sed -n 's/.*--csrf_token \([^ ]*\).*/\1/p')"

lsof_output="$(/usr/sbin/lsof -nP -a -p "${pid}" -iTCP@127.0.0.1 -sTCP:LISTEN)"
https_port="$(printf '%s\n' "${lsof_output}" | /usr/bin/sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\) (LISTEN).*/\1/p' | /usr/bin/head -n 1)"
if [[ ! "${https_port}" =~ ^[0-9]+$ ]] || (( https_port < 1 || https_port > 65535 )); then
  echo "无法发现 Antigravity language_server 的 HTTPS 端口" >&2
  exit 1
fi

headers=(
  -H 'Content-Type: application/json'
)
if [[ -n "${csrf_token}" ]]; then
  headers+=(-H "x-codeium-csrf-token: ${csrf_token}")
fi

quota_json="$(
  /usr/bin/curl --silent --show-error --insecure --fail-with-body \
    --connect-timeout 2 --max-time 10 \
    -X POST "https://127.0.0.1:${https_port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary" \
    "${headers[@]}" \
    --data '{}'
)"

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
