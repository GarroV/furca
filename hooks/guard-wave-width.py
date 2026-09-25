#!/usr/bin/env python3
"""Сторож содержания волны: блок-агент не запускается на служебных задачах.

Ставится на событие PreToolUse и смотрит запуски блок-агентов, пока в проекте
идёт стройка. Отказ у него ровно один: волна, все задачи которой помечены блоком
`chores`, — то есть заход, который построит оснастку вместо продукта. Короткие
роли (`SHORT_ROLES`) волной не считаются: они живут минуты, а `norma` ещё и
единственная, кем закрывается сверка экрана.

**Чего здесь больше нет.** До 25.09.2026 этот же хук считал ширину волны от
остатка лимита подписки: предупреждал с 70%, сужал до одного блока к 85%,
запрещал запуск за порогом останова; сами пороги были грубыми намеренно — снято
25.09.2026 вместе со всем механизмом ширины, решение владельца. Снят и останов
стройки по лимиту в `keep-building.py`. Причина не в том, что лимит перестал
существовать, а в том, что снимок расхода в `~/.claude.json` не описывает эту
сессию: работа идёт через оркестратор, подписки переключаются, в файл пишут
сессии разных учёток (`GarroV/dotfiles#22`), а харнесс обновляет его рывками —
замерены возраст в сутки (20.09) и в двое суток (25.09). Решения по такому числу
ошибались в обе стороны, и обе дорого: волна сужалась до одного блока при пустом
окне, а на выбранном окне механизм молчал, и волна доходила до отказа API
(#151, #156).

Решение владельца 25.09.2026, дословно: «надо смириться что идем до отказа волны
и сохранять прогресс с какой-то регулярностью». Поэтому защита от обрыва теперь
не в предсказании лимита, а в частоте сохранения: состояние диспетчера коммитится
по ходу (сторож непрерывности), блок коммитит и пушит после каждой закрытой
задачи (бриф блок-агента). Об этом хук и напоминает при запуске блока — это
единственное, что он говорит, когда не отказывает.
"""

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

# Инструменты запуска субагента: харнесс зовёт их по-разному в разных версиях.
AGENT_TOOLS = ("Agent", "Task")

# Роли, которые волной не считаются: они живут минуты и не строят блок.
#
# Список закрытый, а не «всё кроме artifex»: незнакомая роль считается блоком.
SHORT_ROLES = ("norma", "optio", "exploratio")


def load_keep_building():
    path = Path(__file__).resolve().parent / "keep-building.py"
    spec = importlib.util.spec_from_file_location("furca_keep_building", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def launched_role(payload: dict) -> str:
    """Роль агента, которого запускают этим вызовом.

    Это не роль вызывающего (её знает `guard-image-reads.py`), а поле
    `subagent_type` в параметрах самого вызова: харнесс кладёт туда имя роли,
    которую просят поднять. Нет поля — пустая строка, и такой запуск считается
    блоком: молчаливое расширение волны хуже лишней строчки в предупреждении.
    """
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    role = tool_input.get("subagent_type")
    return role if isinstance(role, str) else ""


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))


def inform(context: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": context,
        }
    }, ensure_ascii=False))


# В графе задач служебные дела помечены блоком `chores`: оснастка, форматы
# отчётов, журналы, переезды на новые правила системы. Правило «задачи с блоком
# chores агенту не отдаются» стоит в скилле стройки текстом — и текстом же было
# нарушено 17.09.2026: волна ушла на планку числа тестов, пока пять продуктовых
# задач стояли, а владелец обнаружил это сам и спросил, где работа. Отсюда
# проверка: не новое ограничение, а уже принятое правило, ставшее проверяемым.
CHORES_BLOCK = "chores"
TASK_ID = re.compile(r"\bT\d{3,}\b")
# Строка графа: | T012 | core | — | todo | ... |
TASK_ROW = re.compile(r"^\|\s*(T\d{3,})\s*\|\s*([^|]+?)\s*\|", re.M)


def brief_task_ids(payload: dict):
    """Идентификаторы задач, названные в брифе запускаемого агента."""
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return []
    prompt = tool_input.get("prompt")
    if not isinstance(prompt, str):
        return []
    seen, ids = set(), []
    for tid in TASK_ID.findall(prompt):
        if tid not in seen:
            seen.add(tid)
            ids.append(tid)
    return ids


def all_tasks_are_chores(payload: dict, root) -> bool:
    """Правда, когда все узнанные задачи брифа — служебные.

    Скупость здесь та же, что у всего сторожа: не нашли в брифе ни одного
    идентификатора, не нашли граф, не нашли в графе ни одной из названных задач —
    значит неизвестно, а неизвестное не запрещается.
    """
    ids = brief_task_ids(payload)
    if not ids:
        return False
    try:
        text = (Path(root) / "tasks.md").read_text(encoding="utf-8")
    except Exception:
        return False
    blocks = {tid: block for tid, block in TASK_ROW.findall(text)}
    known = [blocks[tid] for tid in ids if tid in blocks]
    if not known:
        return False
    return all(block.strip() == CHORES_BLOCK for block in known)


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") not in AGENT_TOOLS:
        return 0
    if launched_role(payload) in SHORT_ROLES:
        return 0

    try:
        kb = load_keep_building()
        root = kb.project_root(payload.get("cwd") or os.getcwd())
        marker = kb.read_marker(kb.marker_path(root))
    except Exception:
        return 0
    if not marker:
        return 0

    if all_tasks_are_chores(payload, root):
        deny("Все задачи этого запуска — служебные (блок `chores` в tasks.md). "
             "Такие задачи блок-агенту не отдаются: их делает диспетчер, и они "
             "не бывают содержанием волны. Возьми в волну продуктовую задачу — "
             "тогда служебные едут вместе с ней; либо сделай их сам, если это "
             "мелочь по дороге; либо вынеси владельцу списком, если это заход "
             "работы. Правило и причина — в скилле стройки, раздел «Ради чего "
             "всё это».")
        return 0

    inform(
        "Волна идёт до отказа по лимиту, а не до предсказания: остаток окна "
        "этой сессии неизвестен никому (решение владельца 25.09.2026). Значит "
        "цена обрыва должна быть мала — потребуй в брифе коммит И ПУШ после "
        "каждой закрытой задачи. Тогда отказ стоит последней задачи, а не блока: "
        "20.09.2026 волна из двух блоков умерла в одну минуту посреди действия, и "
        "уцелело ровно то, что было в origin."
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Сломанный сторож обязан быть незаметным: он запрещает запуск работы, и
        # его отказ не должен превращаться в отказ строить.
        sys.exit(0)
