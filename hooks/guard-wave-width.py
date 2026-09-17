#!/usr/bin/env python3
"""Ограничитель ширины волны: чем меньше лимита, тем уже волна блок-агентов.

Ставится на событие PreToolUse и смотрит запуски блок-агентов, пока в проекте
идёт стройка. Вдали от лимита не вмешивается вовсе; ближе — предупреждает и
называет разумную ширину; на исходе окна разрешает волне ровно одного блока.
Короткие роли (`SHORT_ROLES`) волной не считаются: они живут минуты, а `norma`
ещё и единственная, кем закрывается сверка экрана.

Зачем механизм. Диспетчер выдаёт каждому блоку изолированный стенд и свои порты,
то есть о конфликтах ресурсов машины он думает. Общий лимит сессии ресурсом не
выглядит: он невидим изнутри разговора, и о нём не думает никто. На живом
прогоне четыре блок-агента одной волны оборвались одновременно с «session
limit» — каждый в шаге от сдачи, ни один не успел проверить работу. Четверо
жгут окно вчетверо быстрее одного и умирают все разом, а не по очереди; при
этом теряется именно проверка, потому что она делается последней, — и блок
оказывается «не принят», даже когда код готов.

Почему ограничитель скупой. Он запрещает запуск работы, а ложный запрет
останавливает стройку целиком. Поэтому: до 70% выбранного окна его не
существует; между 70% и 85% он только говорит; и лишь ближе к концу переходит к
отказу — и то оставляя волне одного агента, потому что останавливать стройку
целиком это дело сторожа непрерывности, а не его.
"""

import importlib.util
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

# Ниже этого расхода ограничителя не существует.
WARN_PCT = 70

# Волна, запущенная в пределах этого окна, считается одной волной: агенты
# запускаются подряд, а живут десятками минут.
WAVE_WINDOW_SEC = 600

# Признак жизни стройки моложе этого — она тратит то же окно прямо сейчас.
# Полтора часа при пятичасовом окне: стройка, от которой столько нет ни
# удержания хода, ни запуска агента, либо кончилась, либо стоит, и сужать из-за
# неё волну живой стройке значило бы наказывать за чужой забытый маркер.
ACTIVE_BUILD_SEC = 90 * 60

# Инструменты, которыми запускают агентов. Имя зависит от харнесса, поэтому их
# два: система ставится и там, где инструмент называется иначе.
AGENT_TOOLS = ("Agent", "Task")

# Роли, чей запуск волной не считается. Нагрузка ролей несопоставима: `artifex`
# держит блок часами и поднимает свой стенд, `optio` делает одну механическую
# задачу по готовому контракту, `norma` сверяет один экран и уходит. Считать их
# одним счётчиком — ошибка меры, и она не только задерживает работу: картинки
# разрешены одной `norma`, поэтому «экран сверен с эталоном» нельзя закрыть,
# пока идёт хоть один блок. На прогоне meridius 17.09.2026 так осталось шесть
# задач сверки при готовых снимках, а `norma` получила отказ два захода подряд
# (#119).
#
# Список закрытый, а не «всё кроме artifex»: незнакомая роль считается блоком.
# Ограничитель сужается только там, где известно, что нагрузка мала, — ошибиться
# в эту сторону дешевле, чем пропустить настоящую волну.
SHORT_ROLES = ("norma", "optio", "exploratio")


def load_keep_building():
    path = Path(__file__).resolve().parent / "keep-building.py"
    spec = importlib.util.spec_from_file_location("furca_keep_building", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def recommended_width(pct: int) -> int:
    """Сколько блоков разумно держать в волне при таком расходе.

    Числа грубые намеренно: точной модели расхода нет и быть не может — она
    зависит от размера блоков и модели агентов. Смысл не в точности, а в том,
    чтобы ширина падала раньше, чем окно кончится.
    """
    if pct >= 85:
        return 1
    if pct >= WARN_PCT:
        return 2
    if pct >= 50:
        return 3
    return 4


def active_builds(kb, self_root, now: float):
    """Пути других строек, которые прямо сейчас тратят то же окно подписки.

    Пятичасовое окно — одно на аккаунт, а стройки идут в разных проектах и друг
    о друге не знают: 15.09.2026 три стройки стартовали в одно окно, каждая
    считала остаток своим, и втроём они выбрали его за пять часов, не дойдя ни
    одна до раздачи блоков (#105). Реестр строек лежит рядом — по маркеру на
    проект; здесь он читается целиком, чтобы ширину волны делить на всех живых.

    Любая ошибка чтения — пустой список: ограничитель, сужающий волну по
    догадке, вреднее отсутствующего.
    """
    others = []
    try:
        files = sorted(kb.builds_dir().glob("*.json"))
    except Exception:
        return others

    for f in files:
        try:
            marker = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(marker, dict):
            continue
        project = marker.get("project")
        if not project or marker.get("released_reason"):
            continue
        try:
            if Path(project).resolve() == Path(self_root).resolve():
                continue
        except Exception:
            continue

        stamps = []
        for key in ("last_hold_at", "started_at"):
            raw = marker.get(key)
            if isinstance(raw, str):
                try:
                    stamps.append(datetime.fromisoformat(raw).timestamp())
                except Exception:
                    pass
        launches = marker.get("wave_launches")
        if isinstance(launches, list):
            stamps += [t for t in launches if isinstance(t, (int, float))]
        if stamps and now - max(stamps) < ACTIVE_BUILD_SEC:
            others.append(project)
    return others


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


def fresh_launches(marker: dict, now: float):
    raw = marker.get("wave_launches")
    if not isinstance(raw, list):
        return []
    return [t for t in raw
            if isinstance(t, (int, float)) and now - t < WAVE_WINDOW_SEC]


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

    Скупость здесь та же, что у всего ограничителя: не нашли в брифе ни одного
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
        path = kb.marker_path(root)
        marker = kb.read_marker(path)
    except Exception:
        return 0
    if not marker:
        return 0

    # Проверка стоит ДО разговора о лимите: служебная волна не становится
    # уместной оттого, что окно подписки пустое. Пока система работает, проект
    # строится — оснастка едет вместе с продуктовой задачей, а не вместо неё.
    if all_tasks_are_chores(payload, root):
        deny("Все задачи этого запуска — служебные (блок `chores` в tasks.md). "
             "Такие задачи блок-агенту не отдаются: их делает диспетчер, и они "
             "не бывают содержанием волны. Возьми в волну продуктовую задачу — "
             "тогда служебные едут вместе с ней; либо сделай их сам, если это "
             "мелочь по дороге; либо вынеси владельцу списком, если это заход "
             "работы. Правило и причина — в скилле стройки, раздел «Ради чего "
             "всё это».")
        return 0

    worst = None
    try:
        worst = kb.usage_worst()
    except Exception:
        worst = None

    # Возраст снимка важен не меньше числа в нём. `~/.claude.json` обновляется
    # рывками — замеряли снимок возрастом 1 ч 21 мин, — а пятичасовое окно за
    # это время успевает смениться целиком. Ошибка при этом однонаправленная:
    # протухший снимок почти всегда показывает расход БОЛЬШЕ фактического, и
    # ограничитель душит волны там, где запас есть (06.09.2026 так был отменён
    # уже запущенный блок, час работы ушёл на перезапуск). Поэтому устаревший
    # снимок означает не «всё хорошо» и не «всё плохо», а «неизвестно»: волна
    # сужается до одного блока, и причина называется вслух, чтобы решение было
    # видно в журнале, а не выглядело капризом механизма.
    stale_age = None
    try:
        age = kb.usage_age()
        if age is not None and age > getattr(kb, "USAGE_FRESH_SEC", 15 * 60):
            stale_age = age
    except Exception:
        stale_age = None

    if not worst and stale_age is None:
        return 0

    name, pct = worst if worst else ("неизвестно", 0)
    if stale_age is None and pct < WARN_PCT:
        return 0

    now = time.time()
    launches = fresh_launches(marker, now)
    others = active_builds(kb, root, now)
    # Остаток делится на всех живых, включая себя: иначе каждая стройка
    # планирует волну на полное окно, а тратят они его вместе.
    # Устаревший снимок означает «неизвестно», и незнание не наказывается строже
    # известного расхода: ошибка протухшего снимка однонаправленная — окно
    # сбрасывается, а число в нём остаётся, — поэтому он почти всегда завышает
    # расход, и ширина, посчитанная по нему, уже консервативна. Душить сверх
    # этого до одного блока нечем: так отклонялась работа, на которую запас был
    # (#119). Причина при этом всё равно называется вслух.
    width = max(1, recommended_width(pct) // (len(others) + 1))
    shared = ""
    if stale_age is not None:
        shared += (
            f"\nРасход неизвестен: снимку {int(stale_age // 60)} мин, он мог "
            "описывать уже сброшенное окно. Пока неизвестно — идём по одному "
            "блоку и пишем это в журнал."
        )
    if others:
        names = ", ".join(Path(p).name for p in others)
        shared = (
            f"\nОкно делят {len(others) + 1} стройки — кроме этой идут: {names}. "
            "Остаток поделён между ними: волна у каждой уже, чем была бы в одиночку."
        )

    if len(launches) >= width:
        deny(
            (f"Лимит подписки: окно {name} израсходовано на {pct}%. При таком "
             if stale_age is None else
             "Расход по лимиту подписки неизвестен — снимок устарел. При таком ")
            + f"остатке волна — не больше {width} блок(а/ов), а в этой уже "
            + f"{len(launches)} за последние {WAVE_WINDOW_SEC // 60} минут.\n"
            + "Дождись, пока запущенные сдадут блоки, прими их и запускай "
            "следующий. Волна из нескольких агентов сожжёт окно быстрее и "
            "оборвётся вся разом — причём на проверке, которую каждый делает "
            "последней, так что не примется ни один блок, даже с готовым кодом."
            + shared
        )
        return 0

    marker["wave_launches"] = launches + [now]
    try:
        kb.write_marker(path, marker)
    except Exception:
        pass

    inform(
        (f"Лимит подписки: окно {name} израсходовано на {pct}%. " if stale_age is None
         else "Расход по лимиту подписки неизвестен — снимок устарел. ")
        + "Запуск разрешён, "
        f"но волну держи не шире {width} блок(а/ов) — сейчас в ней "
        f"{len(launches) + 1}.\n"
        "Запиши остаток в журнал стройки вместе с составом волны: если она "
        "оборвётся, причина должна быть видна в файле состояния, а не только в "
        "уведомлении, которое исчезнет вместе с сессией. И потребуй от агентов "
        "коммита после каждой задачи — тогда обрыв стоит одной задачи, а не "
        "всего блока." + shared
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Сломанный ограничитель обязан быть незаметным: он запрещает запуск
        # работы, и его отказ не должен превращаться в отказ строить.
        sys.exit(0)
