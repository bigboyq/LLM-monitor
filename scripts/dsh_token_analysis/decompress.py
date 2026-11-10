#!/usr/bin/env python3
"""Refresh plaintext copies of DSH sessions; outputs contain private conversation data."""
import argparse
import os
from pathlib import Path
import shutil
import tempfile


def decompress(src_root: Path, out_root: Path) -> None:
    # Python 3.14 supplies zstd; older environments can use the existing optional package.
    try:
        from compression import zstd
    except ImportError:
        import zstandard as zstd

    if not src_root.is_dir():
        raise FileNotFoundError(f"Session directory does not exist: {src_root}")
    out_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    out_root.chmod(0o700)
    for path in sorted(src_root.rglob("*")):
        if not (path.name == "session.jsonl" or path.name.endswith((".jsonl.zstd", ".jsonl.zst"))):
            continue
        out = out_root / (path.parent.name + "__" + path.name)
        # Always refresh: a large existing output is not evidence its source is unchanged.
        # Stage a 0600 file so a decode failure cannot replace the last complete output.
        staged = None
        try:
            with tempfile.NamedTemporaryFile(dir=out_root, delete=False) as target:
                staged = Path(target.name)
                if path.suffix == ".jsonl":
                    source = path.open("rb")
                else:
                    source = zstd.open(path, "rb")
                with source:
                    shutil.copyfileobj(source, target, length=1 << 20)
            os.replace(staged, out)
        finally:
            if staged is not None:
                staged.unlink(missing_ok=True)
        print(f"refreshed: {out.name} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.home() / ".dsh/sessions")
    parser.add_argument("--output", type=Path,
                        default=Path(os.environ.get("DSH_PLAIN_DIR", "/tmp/dsh_plain")))
    args = parser.parse_args()
    decompress(args.source, args.output)
