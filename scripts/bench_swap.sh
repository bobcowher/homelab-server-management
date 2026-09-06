#!/usr/bin/env bash
# Benchmark a model through llama-swap. Same prompt for every model.
#   bench_swap.sh <model-name>
set -uo pipefail
M="$1"
P="Write a detailed technical explanation of how reinforcement learning differs from behavior cloning."
curl -s -m 900 localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"$P\"}],\"max_tokens\":200,\"temperature\":0}" \
  -o /tmp/bs.json
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | tr '\n' ' '
python3 - "$M" <<'PY'
import json,sys
d=json.load(open("/tmp/bs.json"))
t=d.get("timings") or {}
if t:
    print("| %-14s | %6.1f | %6.1f |" % (sys.argv[1], t.get("prompt_per_second",0), t.get("predicted_per_second",0)))
else:
    print("| %-14s | ERROR: %s" % (sys.argv[1], str(d)[:120]))
PY
