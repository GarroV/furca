#!/usr/bin/env python3
"""Не давать двум писателям занять один и тот же id в файлах состояния.

Что случилось. 06.09.2026 на живом проекте оказались два D032, два D033, два
T074 и два T075: сессия владельца записывала решения по площадке, а диспетчер
стройки в параллельной сессии принимал блок и заводил свои. Каждый взял
«следующий свободный номер» по тому состоянию файла, которое видел у себя, и
git слил это без конфликта — строки легли в разные места таблицы.

Почему одной проверки на гейте мало. `state-format.test.sh` теперь ловит дубли,
но ловит их ПОСЛЕ слияния, когда на обе записи уже сослались журналы блоков и
CHANGELOG, и развести их стоит переименования с обходом всех ссылок. Здесь же
столкновение видно в момент записи — до того, как оно во что-то превратилось.

Почему запрет, а не предупреждение. Ссылочная целостность после такого слияния
остаётся ЗЕЛЁНОЙ: ссылки разрешаются, только не туда (`Q003 → D032` показывал
на чужое решение). То есть ошибка не проявляется ничем, кроме неверного текста
под верным номером, — и живёт до тех пор, пока её не прочитает человек.

Отдельно — предупреждение о втором писателе. Если в проекте идёт стройка, а
правку делает не её сессия, столкновение id лишь вопрос времени: об этом
говорится словом, без запрета. Владелец в своём проекте хозяин, и запрещать ему
писать в свои файлы система не вправе.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

#: Файлы, где id раздаются. `progress.md` сюда не входит: в нём id только
#: упоминаются, а раздаются в таблицах.
ID_FILES = ("tasks.md", "questions.md", "decisions.md")

#: Строка таблицы, объявляющая id: `| T074 | …`. Упоминание в тексте (в колонке
#: «зависит от», в журнале) под это не подходит — и не должно.
ID_ROW = re.compile(r"^\| *([TQD][0-9]{3}) *\|", re.MULTILINE)

EDIT_TOOLS = ("Edit", "MultiEdit", "Write", "NotebookEdit")


def load_keep_building():
    path = Path(__file__).resolve().parent / "keep-building.py"
    spec = importlib.util.spec_from_file_location("furca_keep_building", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def declared_ids(text: str) -> list[str]:
    return ID_ROW.findall(text or "")


def added_ids(data: dict) -> list[str]:
    """Id, которые правка ОБЪЯВЛЯЕТ заново.

    Переписывание существующей строки под тем же номером — обычная работа
    (сменился статус, дописан текст), поэтому из добавленных вычитается то, что
    правка убирает.
    """
    before, after = [], []
    if "content" in data:                       # Write: файл целиком
        after += declared_ids(str(data.get("content") or ""))
    for edit in data.get("edits") or []:        # MultiEdit
        if isinstance(edit, dict):
            before += declared_ids(str(edit.get("old_string") or ""))
            after += declared_ids(str(edit.get("new_string") or ""))
    if "new_string" in data:                    # Edit
        before += declared_ids(str(data.get("old_string") or ""))
        after += declared_ids(str(data.get("new_string") or ""))

    out = []
    for i in after:
        if i in before:
            before.remove(i)                    # строка переписана, а не заведена
            continue
        if i not in out:
            out.append(i)
    return out


def self_duplicates(data: dict) -> list[str]:
    """Один и тот же id дважды внутри одной правки."""
    text = str(data.get("content") or "") + str(data.get("new_string") or "")
    for edit in data.get("edits") or []:
        if isinstance(edit, dict):
            text += str(edit.get("new_string") or "")
    ids = declared_ids(text)
    return sorted({i for i in ids if ids.count(i) > 1})


def next_free(existing: list[str], letter: str) -> str:
    numbers = [int(i[1:]) for i in existing if i.startswith(letter)]
    return f"{letter}{(max(numbers) + 1) if numbers else 1:03d}"


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


def other_builder(payload: dict, target: Path) -> str | None:
    """Id сессии, которая ведёт стройку в этом проекте, если это не мы."""
    try:
        kb = load_keep_building()
        root = kb.project_root(str(target.parent))
        marker = kb.read_marker(kb.marker_path(root))
    except Exception:
        return None
    if not marker or marker.get("released_reason"):
        return None
    owner = str(marker.get("session_id") or "").strip()
    if not owner:
        return None
    mine = str(payload.get("session_id") or "").strip() or os.environ.get(
        "CLAUDE_CODE_SESSION_ID", ""
    ).strip()
    return None if owner == mine else owner


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") not in EDIT_TOOLS:
        return 0

    data = payload.get("tool_input") or {}
    if not isinstance(data, dict):
        return 0
    raw_path = str(data.get("file_path") or data.get("notebook_path") or "")
    if not raw_path or Path(raw_path).name not in ID_FILES:
        return 0

    target = Path(raw_path)
    try:
        existing = declared_ids(target.read_text(encoding="utf-8"))
    except Exception:
        existing = []

    # Файл целиком перезаписывают (Write) — сравнивать с прежним содержимым
    # нечего: правка не добавляет строки, а заменяет весь набор. Остаётся дубль
    # внутри неё самой.
    whole_file = "content" in data
    clash = sorted({i for i in added_ids(data) if i in existing}) if not whole_file else []
    twins = self_duplicates(data)

    if twins:
        deny(
            f"В правке {target.name} один id объявлен дважды: {', '.join(twins)}.\n"
            "Строка таблицы — это запись, а не текст: два одинаковых номера дают две "
            "разные записи под одним именем, и все ссылки на них потом читаются, но "
            "ведут не туда. Проверка целостности такой файл считает здоровым."
        )
        return 0

    if clash:
        letter = clash[0][0]
        deny(
            f"{target.name}: id {', '.join(clash)} в файле уже занят.\n"
            "Так выглядит запись двух сессий сразу: каждая взяла «следующий свободный» "
            "по своему состоянию файла. После слияния ссылки разрешаются — но не туда "
            f"(06.09.2026 так разъехались D032 и T074 на живом проекте).\n"
            f"Перечитай файл и возьми следующий свободный номер — сейчас это "
            f"{next_free(existing, letter)}."
        )
        return 0

    owner = other_builder(payload, target)
    if owner:
        inform(
            f"В этом проекте идёт стройка, и ведёт её другая сессия ({owner[:8]}…). "
            f"Файлы состояния сейчас пишут двое.\n"
            "Номер для новой записи бери, перечитав файл прямо перед записью, а не из "
            "памяти: диспетчер мог завести свои записи минуту назад. После слияния "
            "веток блоков прогоняй test/state-format.test.sh — столкнувшиеся id ловит он."
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Сломанный страж обязан быть незаметным: он запрещает правку файлов
        # состояния, и его падение не должно превращаться в запрет работать.
        sys.exit(0)
