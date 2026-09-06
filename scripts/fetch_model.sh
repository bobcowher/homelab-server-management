#!/usr/bin/env bash
# Fetch a GGUF from Hugging Face into /data/models, with mandatory checksum
# verification.
#
# Why not llama.cpp's built-in `-hf`:
# Hugging Face shapes throughput per connection. A single stream starts near
# 30 MB/s and decays to ~2 MB/s within a minute; parallel range requests sustain
# ~100 MB/s. Measured on this box, 2026-09-06. So weights are fetched here and
# declared with `file:` in hosts/lab/vars.yml rather than `hf:`.
#
# Why the checksum is not optional:
# A parallel fetch of a 24GB model produced a file of EXACTLY the right length
# whose contents were wrong. It loaded without complaint and generated fluent
# gibberish. Size is not evidence of a good download; only the hash is.
#
# Resumable: re-running continues a partial download.
#
#   fetch_model.sh <hf-repo> <filename> [dest_dir]
set -euo pipefail

REPO="${1:?usage: fetch_model.sh <hf-repo> <filename> [dest]}"
FILE="${2:?usage: fetch_model.sh <hf-repo> <filename> [dest]}"
DEST="${3:-/data/models}"
OUT="$DEST/$FILE"

echo "==> $REPO / $FILE"

# Hugging Face stores the sha256 of each LFS object as its `oid`.
SHA=$(curl -fsS "https://huggingface.co/api/models/$REPO/tree/main?recursive=1" \
  | python3 -c "
import json,sys
want=sys.argv[1]
for f in json.load(sys.stdin):
    if f.get('path')==want:
        print(((f.get('lfs') or {}).get('oid')) or '')
        break
" "$FILE")

if [ -z "$SHA" ]; then
  echo "    ERROR: no sha256 published for $FILE -- refusing to fetch unverifiable weights." >&2
  exit 1
fi
echo "    expecting sha256 $SHA"

# --checksum makes aria2 verify before it renames the file into place, so a bad
# transfer fails loudly instead of landing a plausible-looking model.
aria2c \
  --max-connection-per-server=4 \
  --split=4 \
  --min-split-size=20M \
  --continue=true \
  --auto-file-renaming=false \
  --summary-interval=0 \
  --console-log-level=warn \
  --checksum="sha-256=$SHA" \
  --dir="$DEST" \
  --out="$FILE" \
  "https://huggingface.co/$REPO/resolve/main/$FILE"

# Belt and braces: confirm what actually landed on disk.
echo "    verifying..."
ACTUAL=$(sha256sum "$OUT" | cut -d' ' -f1)
if [ "$ACTUAL" != "$SHA" ]; then
  echo "    ERROR: checksum mismatch after download" >&2
  echo "      expected $SHA" >&2
  echo "      actual   $ACTUAL" >&2
  echo "    Leaving the file in place for inspection; delete it and retry." >&2
  exit 1
fi
echo "    sha256 OK"

# /data/models is group `ml` with setgid so the llm and beekeeper users can read
# the weights; aria2 creates the file with the caller's umask, so set it here.
chgrp ml "$OUT" 2>/dev/null || sudo chgrp ml "$OUT"
chmod 664 "$OUT"
ls -lh "$OUT"
