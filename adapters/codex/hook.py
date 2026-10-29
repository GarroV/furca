#!/usr/bin/env python3
"""Normalize Codex events and reuse FURCA's shared guard policies."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
EVENT = None


def environment():
    env = dict(os.environ)
    home = Path(env.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
    if not home.is_absolute():
        raise ValueError("CODEX_HOME must be absolute")
    home = home.resolve()
    env.update(FURCA_RUNTIME="codex", FURCA_RUNTIME_HOME=str(home / "furca"))
    return env


def native_feedback(text):
    return (text.replace(str(ROOT / "hooks/keep-building.py"),
                         str(ROOT / "adapters/codex/continuity.py"))
            .replace("subagent_type", "agent_type").replace("Claude Code", "Codex"))


def patch_events(payload):
    """Translate each patch's added/removed text; never execute the patch to inspect it."""
    data = payload.get("tool_input") or {}
    patch = data if isinstance(data, str) else data.get("command", data.get("input", ""))
    if not isinstance(patch, str):
        raise ValueError("apply_patch payload has no patch text")
    sections, current = [], None
    for line in patch.splitlines():
        if line.startswith(("*** Add File: ", "*** Update File: ", "*** Delete File: ")):
            kind, path = line[4:].split(": ", 1)
            current = {"kind": kind, "path": path, "before": [], "after": []}
            sections.append(current)
        elif current and line.startswith("*** Move to: "):
            current["move"] = line.split(": ", 1)[1]
        elif current and not line.startswith(("***", "@@")):
            if line.startswith("-"):
                current["before"].append(line[1:])
            elif line.startswith("+"):
                current["after"].append(line[1:])
    if not sections:
        raise ValueError("unrecognised apply_patch format")
    events = []
    seen = set()
    state_names = {"tasks.md", "questions.md", "decisions.md"}
    for part in sections:
        destination = part.get("move", part["path"])
        if part.get("move") and ({Path(part["path"]).name, Path(destination).name} & state_names):
            raise ValueError("state-file moves require a separate validated write; combined patch move is unsupported")
        path = str((Path(payload.get("cwd") or os.getcwd()) / destination).resolve())
        if Path(path).name in state_names:
            if path in seen:
                raise ValueError("repeated state-file target in one patch; combine its hunks in one section")
            seen.add(path)
        if part["kind"] == "Delete File":
            continue
        fields = {"file_path": path}
        if part["kind"] == "Add File":
            fields["content"] = "\n".join(part["after"])
        else:
            fields.update(old_string="\n".join(part["before"]), new_string="\n".join(part["after"]))
        events.append(dict(payload, tool_name="Write" if "content" in fields else "Edit", tool_input=fields))
    return events


def invoke(filename, payload):
    result = subprocess.run([sys.executable, str(ROOT / "hooks" / filename)],
                            input=json.dumps(payload), text=True, capture_output=True,
                            env=environment(), timeout=15)
    if result.returncode not in (0, 2):
        raise ValueError("guard failed: " + filename)
    if result.returncode == 2:
        print(native_feedback(result.stderr), file=sys.stderr, end="")
        raise SystemExit(2)
    if result.stdout.strip():
        return json.loads(native_feedback(result.stdout))
    return {}


def role_metadata(payload):
    """Keep only lifecycle identity/model metadata, never arguments or transcripts."""
    home = Path(environment()["FURCA_RUNTIME_HOME"])
    directory = home / "roles"
    event = payload.get("hook_event_name")
    session = str(payload.get("session_id") or "")
    child = str(payload.get("agent_id") or "")
    role = payload.get("agent_type")
    known = {"artifex", "artifex-hard", "optio", "norma", "exploratio", "lector"}
    if event == "SubagentStart" and role in known and child:
        directory.mkdir(parents=True, exist_ok=True)
        identity = {"agent_type": role, "agent_id": child, "parent_session_id": session,
                    "model_observed": payload.get("model"), "state": "running", "at": time.time()}
        path = directory / (hashlib.sha256(child.encode()).hexdigest() + ".json")
        path.write_text(json.dumps(identity), encoding="utf-8")
    if event == "SubagentStop" and child:
        path = directory / (hashlib.sha256(child.encode()).hexdigest() + ".json")
        if path.is_file():
            identity = json.loads(path.read_text())
            identity.update(state="stopped", stopped_at=time.time())
            path.write_text(json.dumps(identity), encoding="utf-8")
    # Do not guess which parallel child made a tool call from the parent id.
    # Only a runtime-supplied unique agent_id can resolve this registry.
    if not role and child:
        path = directory / (hashlib.sha256(child.encode()).hexdigest() + ".json")
        if path.is_file():
            role = json.loads(path.read_text()).get("agent_type")
    if role in known or os.environ.get("FURCA_CODEX_PROBE") == "1":
        home.mkdir(parents=True, exist_ok=True)
        record = {key: payload.get(key) for key in
                  ("hook_event_name", "session_id", "agent_id", "model", "tool_name")}
        record["agent_type"] = role
        data = payload.get("tool_input")
        record["tool_input_keys"] = sorted(data) if isinstance(data, dict) else []
        with (home / "events.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    return role if role in known else ""


def background_tasks(payload):
    directory = Path(environment()["FURCA_RUNTIME_HOME"]) / "roles"
    live, stale = [], False
    for path in directory.glob("*.json"):
        record = json.loads(path.read_text())
        if record.get("parent_session_id") != payload.get("session_id") or record.get("state") != "running":
            continue
        if time.time() - record.get("at", 0) > 1800:
            stale = True  # lost terminal event: do not invent liveness or restart work
        else:
            live.append({"id": record["agent_id"], "status": "running"})
    return live, stale


def active_build(payload):
    spec = importlib.util.spec_from_file_location("furca_continuity", ROOT / "hooks/keep-building.py")
    module = importlib.util.module_from_spec(spec)
    # The shared policy reads its runtime paths from the environment.
    previous = {key: os.environ.get(key) for key in ("FURCA_RUNTIME", "FURCA_RUNTIME_HOME")}
    os.environ.update({key: environment()[key] for key in previous})
    try:
        spec.loader.exec_module(module)
        root = module.project_root(payload.get("cwd") or os.getcwd())
        marker = module.read_marker(module.marker_path(root))
        return bool(marker and marker.get("session_id") == payload.get("session_id"))
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def main():
    global EVENT
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        raise ValueError("hook input must be an object")
    event = payload.get("hook_event_name")
    EVENT = event
    role = role_metadata(payload)
    if event in ("SubagentStart", "SubagentStop"):
        return 0
    if role:
        payload = dict(payload, agent_type=role)
    if event == "Stop":
        live, stale = background_tasks(payload) if active_build(payload) else ([], False)
        if stale:
            print(json.dumps({"systemMessage": "FURCA worker liveness is unknown: verify old workers before resuming; no duplicate dispatch was requested"}))
            return 0
        payload = dict(payload, background_tasks=live)
        # Existing continuation bounds and fail-open-on-continuity-error remain shared.
        result = subprocess.run([sys.executable, str(ROOT / "hooks/keep-building.py")],
                                input=json.dumps(payload), text=True, capture_output=True,
                                env=environment(), timeout=15)
        print(native_feedback(result.stdout), end="")
        print(native_feedback(result.stderr), file=sys.stderr, end="")
        return result.returncode
    tool = payload.get("tool_name")
    calls = []
    if tool in ("Bash", "exec_command"):
        data = payload.get("tool_input") or {}
        calls.append(("guard-commit-scope.py", dict(payload, tool_name="Bash", tool_input={
            "command": data.get("command", data.get("cmd", ""))})))
    elif tool in ("spawn_agent", "Agent"):
        data = dict(payload.get("tool_input") or {})
        if data.get("agent_type") == "lector":
            return 0  # canonical read-only runner, not an additional build block
        data["subagent_type"] = data.get("agent_type", "")
        data["prompt"] = data.get("message", data.get("prompt", ""))
        if data["subagent_type"] == "artifex-hard":
            data["subagent_type"] = "artifex"
        calls.append(("guard-wave-width.py", dict(payload, tool_name="Agent", tool_input=data)))
    elif tool in ("view_image", "Read"):
        data = payload.get("tool_input") or {}
        calls.append(("guard-image-reads.py", dict(payload, tool_name="Read", tool_input={
            "file_path": data.get("path", data.get("file_path", ""))})))
    elif tool == "apply_patch":
        calls.extend(("guard-state-ids.py", item) for item in patch_events(payload))
    contexts = []
    for filename, normalized in calls:
        output = invoke(filename, normalized)
        specific = output.get("hookSpecificOutput") or {}
        if specific.get("permissionDecision") == "deny":
            print(json.dumps(output, ensure_ascii=False))
            return 0
        if specific.get("additionalContext"):
            contexts.append(specific["additionalContext"])
    if contexts:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                         "additionalContext": "\n".join(contexts)}}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Tool-policy errors cannot silently admit an action. Stop-policy errors
        # cannot trap the user in a continuation loop.
        print("FURCA Codex hook: " + str(error), file=sys.stderr)
        sys.exit(0 if EVENT == "Stop" else 2)
