# Claude Code and Codex integrations

FURCA uses one build process and one set of project documents with separate runtime integrations. The default Claude installation remains supported. Codex does not borrow Claude's models, settings, usage history or credentials.

| Entry point | Purpose | Implementation |
|---|---|---|
| `bash install.sh` / `--runtime claude` | Existing Claude installation | Existing Markdown roles, skills and native Claude hooks |
| `bash install.sh --runtime codex` | Codex installation | `adapters/codex/install.py` |
| `python3 adapters/codex/install.py --check` | Verify generated artifacts and hook registrations | Source/policy hashes and exact generated output |
| `python3 adapters/codex/continuity.py --start . "$CODEX_THREAD_ID"` | Enable continuity for this checkout and session | Codex-local marker; shared continuity policy |
| `python3 adapters/codex/continuity.py --stop .` | Stop this checkout's continuity | Codex-local marker only |
| `python3 adapters/codex/continuity.py --off` | Remove this integration's hooks and markers | Other Codex hooks and all Claude settings preserved |

## Installation and normal use

Run the installer for the selected runtime. With Codex, restart/reload the client, review its hooks through `/hooks`, and verify that a named native role can actually launch. Use the normal FURCA entry skills. A missing role or unsupported nested-worker operation is a reported limitation, not permission to substitute an unnamed worker silently. Worker batches respect the client's available slots.

Codex artifacts live under `$CODEX_HOME` (default `~/.codex`). Its profile is `furca/profile.md`, model policy is `furca/models.json`, native agents are `agents/*.toml`, generated skills are `skills/*/SKILL.md`, and the translated system view is `furca/runtime/`. The installer preserves profiles, policies and unrelated hooks. It refuses to overwrite foreign generated-target files or installation symlinks. Do not delete the source checkout while this integration points to it.

The source workflow and role instructions remain in `skills/`, `templates/` and `agents/`. `adapters/codex/render.py` translates runtime syntax and supplies a Codex contract. Generated artifacts are not edited by hand: edit the source or Codex policy and reinstall. `--check` fails after source, policy or artifact drift. Claude's existing files are not regenerated or moved by the Codex installer.

Set common preferences such as language and stand location in the Codex profile. Configure them according to the machine's existing rules before starting a build; installation does not grant permission to start local containers. Channel credentials, when needed, belong in the Codex-local `furca/channel.env` or the existing environment. The adapter does not copy credentials from Claude and never starts a second Telegram listener.

## Models and role instructions

Codex model assignments live in its own JSON policy. The initial policy uses GPT-6.1 Sol for the dispatcher recommendation and ordinary worker roles, GPT-6 Luna for the read-only runner, and GPT-6 Astra for hard blocks. These are explicit starting assignments, not measured equivalence to Anthropic models. Model availability and quality must be checked on the account and task.

The five canonical roles render as native TOML definitions. `artifex-hard` is an additional native configuration of the same block-agent contract, used for core/security blocks and after two acceptance returns. A native definition can supersede a launch-time model override; using a separate role avoids silently missing escalation. Nonempty `agent_models` in the Codex profile is rejected: change its `models.json` and reinstall instead.

Historical Claude model names and cost measurements in source explanations are historical evidence, not OpenAI pricing or runtime instructions. The Codex runtime contract states that distinction explicitly. Exact current model observation is not inferred from a configured model name.

## Enforcement and limitations

`adapters/codex/hook.py` normalizes native Bash, worker launch, image read and `apply_patch` events into the shared guard policies. A patch is inspected without executing it: added/removed declarations become state-id checks. `artifex-hard` receives the same block-launch checks as `artifex`. Tool-policy translation errors refuse the call; continuity errors release the turn rather than trapping the user.

Codex Stop invokes the existing bounded continuity decision. Context size and compaction threshold are reported as unavailable; Claude transcripts and usage snapshots are never used as a substitute. Registration checks do not establish hook trust or interception in a live client. Test the actual paths used by that client, including shell calls through its orchestration layer.

Project task state and acceptance evidence stay in the existing project files. Runtime-local session/worker handles and continuity markers stay separate. To hand off, stop the old dispatcher and workers, preserve their output, then let the new runtime re-read state and enable its own continuity. A completed/interrupted Codex worker is continued by launching a fresh named role from those files, not by reviving its old handle through followup/send_input. Chat transcripts and worker handles are not portable. Simultaneous dispatchers on the same state are not supported; the existing ownership/concurrent-build backlog remains relevant (#124, #140, #160).

Lifecycle observations record native role ids and active model fields under Codex's local `furca/` directory. The Stop adapter releases the parent while recorded workers are running. A missing terminal event older than thirty minutes reports unknown liveness and releases rather than silently starting duplicate work. This applies only to an active build. Image-role exceptions use runtime-supplied role/unique child identity; the parent session id is never treated as proof of the caller's role.

## Validation

`bash test/codex.test.sh` exercises installation/profile isolation, preservation of unrelated hooks, stale artifact refusal, native role/effort selection, hard-block configuration, prohibited and permitted tool calls, patch inspection, image-role handling and stopping the adapter. Existing Claude tests remain part of regression validation. These tests use isolated homes and synthetic events; they do not by themselves prove live client hook support or a completed production build.

Codex CLI 0.165.0 and Claude Code 2.1.312 were present during development. Use native custom-agent support and lifecycle hooks as documented in [Codex agents](https://learn.chatgpt.com/docs/agent-configuration/subagents) and [Codex hooks](https://learn.chatgpt.com/docs/hooks); validate other clients/versions before declaring support.
