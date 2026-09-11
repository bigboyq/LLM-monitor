#!/usr/bin/env python3
"""Decompress all dsh session .zstd files into plaintext JSONL."""
import sys
import zstandard
from pathlib import Path

src_root = Path("/tmp/dsh_unpack_zip")
out_root = Path("/tmp/dsh_plain")
out_root.mkdir(exist_ok=True)
src_root.mkdir(exist_ok=True)

# Collect sources from real dsh location
real_root = Path.home() / ".dsh/sessions"
sources = []
for path in real_root.rglob("session.jsonl.zstd"):
    sources.append(path)
for path in real_root.rglob("session.jsonl.zst"):
    sources.append(path)
for path in real_root.rglob("session.jsonl"):
    # already plaintext (rare)
    out = out_root / (path.parent.name + "__" + path.name)
    if not out.exists():
        out.write_bytes(path.read_bytes())
        print(f"plain copy: {out.name} ({out.stat().st_size} bytes)")

dctx = zstandard.ZstdDecompressor()
for path in sources:
    out = out_root / (path.parent.name + "__" + path.name)
    if out.exists() and out.stat().st_size > 100_000:
        continue
    with path.open("rb") as fh:
        reader = dctx.stream_reader(fh, read_across_frames=True, closefd=False)
        chunks = []
        total = 0
        try:
            while True:
                chunk = reader.read(1 << 20)  # 1MB
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
        except Exception as e:
            print(f"FAIL: {path}: {e}")
            continue
        finally:
            reader.close()
    out.write_bytes(b"".join(chunks))
    print(f"decompressed: {out.name} ({total} bytes from {path.stat().st_size} compressed)")
