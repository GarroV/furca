# Supporting OpenAI and Anthropic in FURCA and VIGIL

29 October 2026. Source review and migration proposal; not implemented or a claim of Codex compatibility.

Tracking: [FURCA #191](https://github.com/GarroV/furca/issues/191), [VIGIL #66](https://github.com/GarroV/vigil/issues/66).

## Purpose and user journeys

FURCA should build a product and VIGIL should audit a project through either Claude Code or Codex. Adding OpenAI must preserve the working Anthropic integration. The shared process, acceptance requirements and saved project state should not fork with the model vendor.

| Entry point | Purpose | Current backing implementation |
|---|---|---|
| FURCA skills | Prepare, build, inspect and deploy a project | Claude Code skills, agent definitions and hooks |
| VIGIL skills | Coordinate a complete audit or one role or phase | Claude Code skills and agent definitions |
| `vigil` CLI | Validate and persist audit work and generate reports | Python core without model API calls |
| FURCA channel | Deliver questions and collect owner replies | Separate HTTP service and Telegram bot |

A person should be able to choose one supported runtime, install only its integration and work through the same process. After an interruption, another supported runtime should reconstruct pending work from files and evidence. This does not mean transferring a vendor's chat transcript or resuming its agent handle. Concurrent ownership of the same build or role needs explicit coordination.

**Terms:** a provider supplies models; a runtime supplies the agent loop, tools and permissions; an adapter translates shared operations into that runtime's native interfaces. A role describes responsibility and acceptance, not a particular model.

## Findings in the current implementation

### FURCA has runtime dependencies inside its workflow

- `install.sh` installs into `~/.claude`, links Markdown agent definitions and registers Claude-specific tool matchers in `settings.json`.
- `agents/*.md` set `sonnet` or `haiku`; `skills/fabrica/SKILL.md` sets `opus` for difficult or repeatedly rejected blocks. Model policy is distributed across definitions, skills and briefs.
- `skills/ordo/SKILL.md` and `skills/fabrica/SKILL.md` require named `subagent_type` launches. They explicitly reject an improvised generic agent. Copying these skills into Codex is not a supported execution path.
- `hooks/keep-building.py` combines useful build policy with Claude profile paths, transcript usage records, session identity and hook continuation semantics.
- Other guards depend on Claude tool payloads, agent identity and edit representations. An `apply_patch` invocation cannot be treated as a Claude `Edit` payload by renaming the matcher alone.
- `templates/block-agent-brief.md` includes Claude-specific delegation, model explanations, background-agent behaviour and commit attribution. Those details must belong to the relevant adapter.
- The shared project documents, task dependencies, block contracts and acceptance requirements are reusable. The channel's HTTP interface can also remain shared; local credential discovery must be independent of runtime.

Existing backlog items #124, #140 and #160 concern ownership/state collisions; #142 concerns alternative block execution modes; #184 and #189 concern worker lifecycle. A portable implementation must account for these boundaries without claiming to have fixed them merely by adding an adapter.

### VIGIL is closer to being portable

- `bin/vigil`, `lib/vigil/` and `schemas/` already provide phase gates, role write boundaries, identity, evidence, risk, coverage and reports without calling a model provider.
- `lib/vigil/profile.py` still hardcodes `~/.claude/vigil/profile.md` and defaults the session recommendation to `opus`.
- `install.sh` installs only Claude skills and Markdown agents. Each of the twelve role definitions has an Anthropic model alias.
- `skills/vigil-audit/SKILL.md` discovers installed roles in `~/.claude/agents`, assumes Claude launch semantics and applies Anthropic model overrides. It requires role definitions to enter as role instructions, not as an ordinary user message.
- Audit state records phase and role completion. Portable execution also needs structured records of the actual runtime, provider, model and role-definition version used for each attempt; a requested model is not proof of the model that ran.
- The dispatch skill still describes six analyzers although `lib/vigil/roles.py` defines eight. This is already tracked by VIGIL #64; deriving dispatch inventory from the core avoids repeating the drift in two adapters.

## Proposed separation

Maintain one authoritative definition of each role's purpose, inputs, permitted outputs and acceptance criteria. Keep runtime-specific launch instructions, model assignments, tool handling, installation and configuration separate. Where native agent files repeat common role text, generate them deterministically and check them for drift rather than maintaining two independent copies.

Keep the current Claude files and installation behaviour working during migration. Introduce an explicit Codex installation target first; do not bulk-move the Claude integration or overwrite user settings. Later extraction of shared content must preserve the Claude behaviour through regression checks.

Use separate runtime configuration layers. Shared defaults may contain language, safety ceilings and workflow policy; a Codex-specific layer must never silently change Claude's models or settings. Runtime selection must be explicit and must not depend on whichever home-directory profile happens to exist.

The adapter contract should cover:

- Resolve a role to a supported model and effort; expose the effective choice and refuse an unavailable required capability.
- Launch, wait, message, cancel and collect an attempt, including timeout, interruption and incomplete output.
- Translate lifecycle and tool events into the shared guard policy and return native enforcement decisions.
- Report capability support: nested workers, isolated worktrees, tool interception, role identity, continuation and context telemetry. Unknown capabilities are not assumed to be present.
- Preserve structured evidence and attempt identity in shared project state. Runtime-local session and worker handles stay in runtime-local state.

Do not automatically replace `opus`, `sonnet`, `haiku` with a fixed OpenAI trio. Specify role requirements first, then test configurable model assignments. VIGIL's proof and judgement roles must not be downgraded just to match a pricing tier.

Provider portability and runtime portability are separate requirements. Native Codex subagents inherit their parent's provider, so allowing Claude Code or Codex runs does not itself implement a mixed-vendor agent tree. Mixed-vendor execution in one run would need a separate runner and is not necessary for the first migration.

## Safety and continuation

Identically named hooks do not guarantee equivalent input or enforcement. Validate actual installation and intercepted tool calls in each supported client/version. A configured file or a passing policy-unit-test is insufficient evidence that a live client invokes the guard.

Preserve FURCA's continuation limits, stop conditions and owner-controlled deployment. If a runtime cannot keep a build active, expose that limitation instead of promising autonomy. Preserve VIGIL's safety ceiling, role write lanes and `INCOMPLETE` semantics. Role instructions alone do not establish a read-only operating-system sandbox.

Shared run identity should include project, run, role, attempt and checked revision. Ownership transfer must not accept stale worker completion, start duplicate work or reuse another runtime's approval. Schema changes need a version and a reader for existing state; existing histories must remain usable without rewriting them.

## Suggested sequence and acceptance

1. Define the shared role, adapter and attempt contracts. Record the supported clients and minimum versions. Keep existing entry points working.
2. Pilot VIGIL: select the profile explicitly, add Codex-native role definitions and dispatch, then run the same planted fixture through both runtimes. Compare confirmed evidence, coverage and honest incompleteness, not identical prose.
3. Separate FURCA role policy and lifecycle translation. Add Codex installation without modifying the Claude installation or Orca hooks.
4. Run a small FURCA build through each runtime. Interrupt and continue across runtimes; test worker failure, ownership collisions and resubmitted output. Establish schema compatibility and idempotent acceptance.
5. Prove each runtime guard with a prohibited synthetic action, then a permitted action. Verify no changes to the other runtime's settings, profiles or active work.

Supporting each runtime separately and transferring work between them is the first target. Simultaneous mixed-vendor execution is a distinct future decision.

## Validation performed

Source reviewed: installers, defaults, agent definitions, dispatch skills, relevant guards, VIGIL profile/core/role schema and existing issue lists. No live audit or product build was launched and no model API credentials were used.

All of the following existing test scripts exited 0:

- FURCA: `package`, `install`, `agents`, `hook`, `image-reads`, `state-ids`, `compact-prep` (`test/<name>.test.sh`).
- VIGIL: `install`, `agents`, `schema`, `lanes`, `rolesrun`, `pipeline` (`test/<name>.test.sh`).

These are baseline checks of the current implementation, including its existing synthetic negative cases. They do not establish live Codex support, real cross-runtime continuation, model quality or whole-system regression safety. Full suites, channel/database integration and client-level hook probes were not run.

## Runtime documentation checked

- [Codex custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents): native TOML definitions, model/effort settings and inherited provider/permissions.
- [Codex hooks](https://learn.chatgpt.com/docs/hooks): lifecycle events, tool payloads and enforcement limitations.
- [Claude Code subagents](https://code.claude.com/docs/en/sub-agents): native role definitions and execution lifecycle.
- [Claude Code hooks](https://code.claude.com/docs/en/hooks): native lifecycle contract.

Documentation describes product capabilities; the installed client and this session must still demonstrate them before being declared supported.
