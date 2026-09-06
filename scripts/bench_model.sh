#!/usr/bin/env bash
# Benchmark one llama.cpp GPU placement. Prints VRAM per card and tok/s.
#   bench_model.sh <label> <gpus-arg> [extra llama-server args...]
set -uo pipefail

LABEL="$1"; GPUS="$2"; shift 2
PORT=8099
NAME="bench-$$"
IMG=ghcr.io/ggml-org/llama.cpp:server-cuda
MODEL=/models/Laguna-XS-2.1-Q4_K_M.gguf
LOG=/tmp/bench-$LABEL.log

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "=============================================================="
echo "CONFIG: $LABEL"
echo "  gpus: $GPUS"
echo "  args: $*"

# shellcheck disable=SC2086
docker run -d --name "$NAME" --network host --gpus $GPUS \
  -e LLAMA_CACHE=/models/hf-cache -v /data/models:/models \
  "$IMG" -m "$MODEL" --host 127.0.0.1 --port $PORT "$@" >/dev/null 2>&1

# wait for health, up to 300s
ok=0
for _ in $(seq 1 300); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:$PORT/health 2>/dev/null)" = "200" ]; then
    ok=1; break
  fi
  if ! docker ps -q -f name="$NAME" | grep -q .; then
    echo "  RESULT: FAILED TO START"
    docker logs "$NAME" 2>&1 | tail -15
    return 2>/dev/null || exit 0
  fi
  sleep 1
done
docker logs "$NAME" > "$LOG" 2>&1

if [ "$ok" != "1" ]; then
  echo "  RESULT: TIMED OUT waiting for health"
  tail -15 "$LOG"; exit 0
fi

echo "--- VRAM in use (nvidia-smi order: 0=3060, 1=3090) ---"
nvidia-smi --query-gpu=index,name,memory.used --format=csv,noheader

echo "--- generating 200 tokens ---"
RESP=$(curl -s -m 600 localhost:$PORT/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"m","messages":[{"role":"user","content":"Write a detailed technical explanation of how reinforcement learning differs from behavior cloning."}],"max_tokens":200,"temperature":0,"stream":false}')

echo "$RESP" > /tmp/bench-resp.json
python3 - /tmp/bench-resp.json <<'PYE'
import json,sys
d=json.load(open(sys.argv[1]))
t=d.get("timings") or {}
if t:
    print("  prompt : %.1f tok/s" % t.get("prompt_per_second",0))
    print("  GEN    : %.1f tok/s  (%s tokens)" % (t.get("predicted_per_second",0), t.get("predicted_n")))
else:
    print("  no timings; usage:", d.get("usage"))
PYE
grep -E "offloaded|assigned to device|CUDA[0-9] model buffer|KV self size" "$LOG" | head -12
