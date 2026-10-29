"""Translate runtime syntax, not the shared build/acceptance requirements."""
import re


def render(text, home, policy):
    text = re.sub(r"Определение даёт \*\*Sonnet\*\*:.*?(?=- \*\*Блок с)",
                  "В Codex обычный блок запускается ролью `artifex`. Для двух случаев ниже "
                  "запускай нативную роль `artifex-hard`: её модель закреплена отдельно, "
                  "поэтому эскалация не зависит от переопределения модели при запуске.\n\n", text, flags=re.S)
    text = text.replace('— `model: "opus"`.', '— нативная роль `artifex-hard`.')
    text = re.sub(r"Единственное, что перебивает всё это, — непустой `agent_models.block_agent`.*?(?=\n\n)",
                  "В Codex модели меняются только в его `models.json` с повторной установкой. "
                  "Непустой `agent_models` из профиля не поддерживается и должен быть снят явно.", text, flags=re.S)
    text = text.replace("~/.claude/furca", str(home / "furca"))
    text = text.replace("~/.claude/agents", str(home / "agents"))
    text = text.replace("~/.claude/skills", str(home / "skills"))
    text = text.replace("Claude Code", "Codex").replace("claude --model", "codex --model")
    text = text.replace("subagent_type:", "agent_type:")
    text = text.replace('model: "opus"', 'model: "' + policy["hard_model"] + '"')
    text = text.replace("<forge_home>/hooks/keep-building.py", "<forge_home>/adapters/codex/continuity.py")
    text = text.replace("--start .  # включить для этого проекта", "--start . \"$CODEX_THREAD_ID\"  # включить для этой сессии")
    # This probe reads a different product's config; Codex telemetry is explicitly unknown.
    text = re.sub(r"5а\. \*\*Проверь порог компакта.*?(?=\n6\. \*\*)",
                  "5а. **Контекст Codex.** Точный порог компакта адаптеру неизвестен. "
                  "Не читай настройки Claude и не обещай подготовку по его телеметрии. "
                  "Сохраняй состояние по ходу; после компакта восстанавливай его из файлов.\n", text, flags=re.S)
    text = re.sub(r"Your model was chosen deliberately:.*?(?=You own the block)",
                  "Your model and effort come from the Codex role policy. "
                  "Hard blocks and escalation use its explicit hard_model, never an Anthropic alias. ",
                  text, flags=re.S)
    text = re.sub(r"- \*\*Never wait with `sleep`\.\*\*.*?(?=\n- \*\*)",
                  "- **Wait on the runtime's native worker/session handle.** Use native wait/poll "
                  "tools for running commands and workers; do not invent Monitor or ToolSearch tools.\n",
                  text, flags=re.S)
    text = re.sub(r"## Long operations:.*?(?=\n## Waiting)",
                  "## Long operations\n\nUse native process handles and bounded waits. "
                  "Run relevant checks as you go, commit completed work, and do not return "
                  "while your verification is still running.\n", text, flags=re.S)
    text = re.sub(r"## Waiting for something to finish:.*?(?=\n## )",
                  "## Waiting for something to finish\n\nWait through native worker or command "
                  "handles. Report a failure or interruption; do not assume background work "
                  "completed after the worker returned.\n", text, flags=re.S)
    text = re.sub(r"^Co-Authored-By: Claude[^\n]*\n", "", text, flags=re.M)
    text = text.replace("SendMessage", "the native worker messaging tool")
    text = text.replace("`Monitor` с until-циклом", "нативный инструмент ожидания по дескриптору процесса или агента")
    text = re.sub(r"4\. \*\*The Telegram plugin in Codex must be OFF\*\*.*?in the settings does\.",
                  "4. **Do not start a Telegram listener in Codex.** Use the standing channel's "
                  "HTTP API. If a Telegram plugin is installed, disable its listener through "
                  "the supported Codex settings. Never edit Claude settings for this purpose; "
                  "if no such plugin is installed, there is nothing to disable.", text, flags=re.S)
    return text


def contract(home, policy):
    return (
        "## Codex runtime contract\n\n"
        "This layer translates runtime-specific details of the shared workflow below; "
        "it never weakens safety, scope, verification or owner approvals. "
        "Launch native named roles with Codex's available agent tools. An `agent_type` "
        "example means select that native role; do not invent Claude tool calls. "
        "If a role, nested worker, message or hook capability is unavailable, report it and "
        "stop dependent work rather than silently substituting an inherited generic worker. "
        "A completed or interrupted worker is continued by launching a fresh named role from "
        "saved project state, not by resuming its old handle with followup/send_input. "
        "Use bounded parallel batches; native roles inherit parent permissions.\n\n"
        f"Model policy: `{home / 'furca/models.json'}`. Session recommendation: "
        f"`{policy['session']}`; hard-block/escalation model: `{policy['hard_model']}`. "
        "All other Anthropic model names and cost measurements in historical explanations "
        "below describe the original Claude implementation, not OpenAI pricing or "
        "model selection. Model overrides go in Codex models.json followed by reinstall, "
        "not agent_models or a spawn override that a native definition could supersede. Do not claim a "
        "configured model was observed. Never add Claude authorship to a Codex commit.\n\n"
        "Do not read Claude configuration, usage snapshots, agent transcripts or credentials. "
        "Precise context/usage telemetry is unavailable in this adapter. Runtime metadata "
        "lives in the Codex home; task state and acceptance evidence stay in project files. "
        "Before a cross-runtime handoff, stop the old dispatcher and workers, preserve "
        "their evidence, and re-read state; never run two dispatchers on the same state.\n\n"
    )
