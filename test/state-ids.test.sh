#!/usr/bin/env bash
set -uo pipefail

# Тесты стража идентификаторов состояния. 06.09.2026 на живом проекте
# оказались два D032, два D033, два T074 и два T075: сессия владельца и
# диспетчер стройки писали в файлы состояния одновременно, каждый брал
# «следующий свободный» по своему состоянию файла, а git слил строки без
# конфликта (issue #92). Проверка целостности после такого слияния ЗЕЛЁНАЯ:
# ссылки разрешаются, только ведут не туда.
#
# Страж скупой: он запрещает правку файлов состояния, а ложный запрет
# останавливает и стройку, и работу владельца в его собственном проекте.
# Поэтому отказ — только на доказанном столкновении номеров, а второй писатель
# — повод сказать словом, а не запретить.

FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$FURCA_HOME/hooks/guard-state-ids.py"
KEEP="$FURCA_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$GUARD" ]] || { echo "FAIL: нет файла стража $GUARD"; exit 1; }

passed=0; failed=0
ok()   { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad()  { failed=$((failed+1)); printf '  FAIL %s — вывод: %s\n' "$1" "${OUT:0:220}"; }
expect_deny()   { [[ "$OUT" == *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_warn()   { [[ "$OUT" == *"additionalContext"* && "$OUT" != *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_silent() { [[ -z "$OUT" ]] && ok "$1" || bad "$1"; }

PROJECT="$WORK/project"
mkdir -p "$PROJECT/docs/furca"
cat > "$PROJECT/tasks.md" <<'EOF'
| id | block | depends on | status | task |
|---|---|---|---|---|
| T001 | api | — | done | Схема БД |
| T002 | api | T001 | todo | Ручки |
EOF
cat > "$PROJECT/docs/furca/decisions.md" <<'EOF'
| id | дата | решение |
|---|---|---|
| D031 | 2026-09-06 | Площадка — muspelheim |
EOF
echo "# Журнал" > "$PROJECT/progress.md"
printf '| id | вопрос | блокирует | статус |\n|---|---|---|---|\n' > "$PROJECT/docs/furca/questions.md"
git -C "$PROJECT" init -q
git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -qm init

# $1 — инструмент, $2 — файл, дальше пары ключ=значение полей tool_input.
call_guard() {
  local tool="$1" file="$2"; shift 2
  local payload
  payload="$(python3 - "$tool" "$file" "$@" <<'PY'
import json, sys
tool, path, *rest = sys.argv[1:]
data = {"file_path": path}
for pair in rest:
    key, _, value = pair.partition("=")
    data[key] = value
print(json.dumps({"session_id": "сессия-владельца", "cwd": path,
                  "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": data}))
PY
)"
  OUT="$(printf '%s' "$payload" | CLAUDE_CODE_SESSION_ID=сессия-владельца python3 "$GUARD" 2>/dev/null)"
}

echo "id состояния: не своё дело"

call_guard Edit "$PROJECT/README.md" old_string=старое new_string='| T001 | api | — | todo | Другое |'
expect_silent "файл не из файлов состояния — страж молчит"

call_guard Edit "$PROJECT/progress.md" old_string=# new_string='# 2026-09-17 12:00 T001 сделана'
expect_silent "журнал упоминает id, но не раздаёт их"

echo
echo "id состояния: столкновение номеров"

call_guard Edit "$PROJECT/tasks.md" \
  old_string='| T002 | api | T001 | todo | Ручки |' \
  new_string='| T002 | api | T001 | todo | Ручки |
| T003 | api | T002 | todo | Тесты ручек |'
expect_silent "свободный номер — обычная работа"

call_guard Edit "$PROJECT/tasks.md" \
  old_string='| T002 | api | T001 | todo | Ручки |' \
  new_string='| T002 | api | T001 | todo | Ручки |
| T001 | web | — | todo | Вторая сессия взяла тот же номер |'
expect_deny "номер уже занят — отказ"
[[ "$OUT" == *"T003"* ]] && ok "в отказе назван следующий свободный номер" || bad "отказ не говорит, какой номер брать"

call_guard Edit "$PROJECT/tasks.md" \
  old_string='| T001 | api | — | done | Схема БД |' \
  new_string='| T001 | api | — | done | Схема БД (уточнено) |'
expect_silent "переписать существующую строку под тем же номером — не столкновение"

call_guard Edit "$PROJECT/docs/furca/decisions.md" \
  old_string='| D031 | 2026-09-06 | Площадка — muspelheim |' \
  new_string='| D031 | 2026-09-06 | Площадка — muspelheim |
| D031 | 2026-09-17 | Второе решение под тем же номером |'
expect_deny "решения считаются так же, как задачи"

call_guard Write "$PROJECT/tasks.md" \
  content='| id | block | depends on | status | task |
|---|---|---|---|---|
| T001 | api | — | done | Схема БД |
| T001 | web | — | todo | Дубль внутри одной правки |'
expect_deny "дубль внутри самой правки — отказ, даже когда файл переписывают целиком"

call_guard Write "$PROJECT/tasks.md" \
  content='| id | block | depends on | status | task |
|---|---|---|---|---|
| T001 | api | — | done | Схема БД |
| T002 | api | T001 | done | Ручки |'
expect_silent "перезапись файла теми же номерами — обычная работа"

echo
echo "id состояния: второй писатель"

# Стройку ведёт другая сессия: столкновение id — вопрос времени, но запрещать
# владельцу писать в свои файлы страж не вправе.
CLAUDE_CODE_SESSION_ID=диспетчер python3 "$KEEP" --start "$PROJECT" > /dev/null
call_guard Edit "$PROJECT/tasks.md" \
  old_string='| T002 | api | T001 | todo | Ручки |' \
  new_string='| T002 | api | T001 | todo | Ручки |
| T004 | web | — | todo | Запись владельца во время стройки |'
expect_warn "идёт чужая стройка — предупреждение, но правка разрешена"
[[ "$OUT" == *"перечитав файл"* ]] && ok "сказано, как брать номер при двух писателях" || bad "предупреждение не говорит, что делать"

# Та же сессия, что ведёт стройку, предупреждать себя не должна.
OUT="$(python3 - "$PROJECT/tasks.md" <<'PY' | CLAUDE_CODE_SESSION_ID=диспетчер python3 "$GUARD" 2>/dev/null
import json, sys
path = sys.argv[1]
print(json.dumps({"session_id": "диспетчер", "cwd": path, "hook_event_name": "PreToolUse",
                  "tool_name": "Edit",
                  "tool_input": {"file_path": path,
                                 "old_string": "| T002 | api | T001 | todo | Ручки |",
                                 "new_string": "| T002 | api | T001 | todo | Ручки |\n| T005 | web | — | todo | Запись диспетчера |"}}))
PY
)"
expect_silent "диспетчер сам себе не второй писатель"

echo
echo "id состояния: собой ничего не ломает"
printf 'мусор' | python3 "$GUARD" >/dev/null 2>&1 && ok "мусор на входе — выход 0" || bad "мусор валит стража"
call_guard Bash "$PROJECT/tasks.md"
expect_silent "не правка файла — страж молчит"

echo
if (( failed == 0 )); then echo "PASS ($passed)"; else echo "ПРОВАЛЕНО: $failed, прошло: $passed"; exit 1; fi
