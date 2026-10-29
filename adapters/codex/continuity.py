#!/usr/bin/env python3
"""Codex-local management of the shared continuity policy; never edit Claude settings."""
import json
import os
from pathlib import Path
import subprocess
import sys

from hook import ROOT, environment


def main():
    args = sys.argv[1:]
    env = environment()
    home = Path(env["FURCA_RUNTIME_HOME"])
    mode = args[0] if args else "--check"
    if mode == "--check":
        return subprocess.call([sys.executable, str(ROOT / "adapters/codex/install.py"), "--check"], env=env)
    if mode == "--off":
        # Remove only this adapter's entries, preserving every other Codex hook.
        path = home.parent / "hooks.json"
        data = json.loads(path.read_text())
        for event, groups in list(data.get("hooks", {}).items()):
            kept = []
            for group in groups:
                hooks = [h for h in group.get("hooks", [])
                         if str(ROOT / "adapters/codex/hook.py") not in h.get("command", "")]
                if hooks:
                    kept.append(dict(group, hooks=hooks))
            data["hooks"][event] = kept
        tmp = path.with_suffix(".furca-tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n"); tmp.replace(path)
        for marker in (home / "builds").glob("*.json"):
            marker.unlink()
        print("Codex continuity disabled; Claude and unrelated hooks unchanged")
        return 0
    if mode not in ("--start", "--stop", "--status", "--marker-path"):
        print("unsupported continuity mode", file=sys.stderr)
        return 2
    if mode == "--start" and len(args) < 3:
        session = os.environ.get("CODEX_THREAD_ID", "")
        if not session:
            print("--start requires the Codex session id as third argument (or CODEX_THREAD_ID)", file=sys.stderr)
            return 2
        if len(args) == 1:
            args.append(os.getcwd())
        args.append(session)
    return subprocess.call([sys.executable, str(ROOT / "hooks/keep-building.py"), *args], env=env)


if __name__ == "__main__":
    sys.exit(main())
