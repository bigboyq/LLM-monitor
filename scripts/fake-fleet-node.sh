#!/usr/bin/env bash
# 仿真 fleet 副节点：向 hub POST 一份 NodeUsageReport，制造测试节点。
# 用法：
#   scripts/fake-fleet-node.sh                       # 默认 3 个节点各推一次
#   scripts/fake-fleet-node.sh -n 5                  # 5 个节点
#   scripts/fake-fleet-node.sh -h 192.168.88.27:8787 # 指定 hub
#   scripts/fake-fleet-node.sh -n 1 --tokens 500000  # 单节点改今日 token
# 节点身份按序稳定（node-1/2/3…，seq 自增持久在 /tmp/fake-fleet-seqs），
# 重复执行同一脚本 = 同一批节点的后续心跳，不会产生新节点。
set -euo pipefail

HUB="127.0.0.1:8787"
COUNT=3
TOKENS=1200000

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) HUB="$2"; shift 2 ;;
    -n) COUNT="$2"; shift 2 ;;
    --tokens) TOKENS="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

SEQ_DIR="${TMPDIR:-/tmp}/fake-fleet-seqs"
mkdir -p "$SEQ_DIR"

node_report() {
  local idx="$1" seq="$2" tokens="$3"
  local now today
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  today=$(date +%F)

  python3 - "$idx" "$seq" "$tokens" "$now" "$today" <<'PY'
import json, sys, datetime, uuid

idx, seq, tokens, now, today = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
node_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"fake-fleet-node-{idx}"))
days = [(datetime.date.fromisoformat(today) - datetime.timedelta(days=i)).isoformat() for i in range(6, -1, -1)]
buckets = []
for i, d in enumerate(days):
    # 今日给足 tokens，其余天按衰减给一点，7 天柱图有形状
    day_tokens = tokens if i == 6 else int(tokens * (0.3 + 0.1 * i))
    rows = [{
        "clientID": "codex", "quotaProviderID": "openai",
        "input": int(day_tokens * 0.6), "cacheRead": int(day_tokens * 0.3),
        "output": int(day_tokens * 0.1), "reasoning": 0,
        "turns": max(1, day_tokens // 20000), "rounds": max(1, day_tokens // 10000),
    }] if day_tokens else []
    totals = {k: sum(r[k] for r in rows) for k in ("input", "cacheRead", "output", "reasoning", "turns", "rounds")} if rows else \
             {"input": 0, "cacheRead": 0, "output": 0, "reasoning": 0, "turns": 0, "rounds": 0}
    entries = [{
        "clientID": "codex", "quotaProviderID": "openai", "modelName": "gpt-5.5",
        "input": totals["input"], "cacheRead": totals["cacheRead"],
        "output": totals["output"], "reasoning": 0,
        "value": round(totals["input"] * 0.00000125 + totals["output"] * 0.00001, 4),
        "currency": "USD", "coverage": "full", "truncated": False,
    }] if day_tokens else []
    buckets.append({"dayKey": d, "totals": totals, "clientProviders": rows, "entries": entries,
                    "totalsComplete": True, "modelDetailsComplete": True, "sourceTruncated": False})

report = {
    "protocolVersion": 1,
    "node": {
             "nodeID": node_id,
             "nodeName": f"Test-Node-{idx}", "timezoneID": "Asia/Shanghai", "platform": "macOS"},
    "seq": seq, "generatedAt": now, "attributionFingerprint": "deadbeef",
    "dailyBuckets": buckets, "windowUsage": [], "quotas": [],
}
print(json.dumps(report))
PY
}

for i in $(seq 1 "$COUNT"); do
  seq_file="$SEQ_DIR/node-$i"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  seq=$((seq + 1))
  echo "$seq" > "$seq_file"
  body=$(node_report "$i" "$seq" "$TOKENS")
  status=$(curl -s -o /tmp/fake-fleet-resp.json -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data "$body" "http://$HUB/v1/usage/day")
  if [[ "$status" == "200" ]]; then
    gen=$(python3 -c "import json;print(json.load(open('/tmp/fake-fleet-resp.json'))['generation'])" 2>/dev/null || echo '?')
    echo "Test-Node-$i  seq=$seq  ✓ (hub generation=$gen)"
  else
    echo "Test-Node-$i  seq=$seq  ✗ HTTP $status"
  fi
  sleep 1.1   # hub 每节点 1s 限流
done
