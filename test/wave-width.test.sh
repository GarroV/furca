#!/usr/bin/env bash
set -uo pipefail

# Тесты сторожа содержания волны (`hooks/guard-wave-width.py`).
#
# Отказ у него один: волна, все задачи которой служебные. Правило «задачи с
# блоком chores агенту не отдаются» стояло текстом и текстом же нарушалось — на
# живом прогоне 17.09.2026 волна ушла на оснастку, пока пять продуктовых задач
# стояли, и владелец спросил, где работа.
#
# Ширины по остатку лимита здесь больше нет: снята 25.09.2026 решением владельца
# вместе с остановом стройки по лимиту. Снимок расхода не описывает эту сессию
# (оркестратор, переключение подписок, обновление рывками), и решения по нему
# ошибались в обе стороны — сужали волну на пустом окне и молчали на выбранном.
# Поэтому проверяется и обратное: никакое содержимое снимка запуск не меняет.

FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$FURCA_HOME/hooks/guard-wave-width.py"
KEEP="$FURCA_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$GUARD" ]] || { echo "FAIL: нет файла сторожа $GUARD"; exit 1; }

passed=0; failed=0

ok()   { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad()  { failed=$((failed+1)); printf '  FAIL %s — вывод: %s\n' "$1" "${GUARD_OUT:0:200}"; }
expect_deny()   { [[ "$GUARD_OUT" == *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_allow()  { [[ "$GUARD_OUT" == *"additionalContext"* && "$GUARD_OUT" != *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_silent() { [[ -z "$GUARD_OUT" ]] && ok "$1" || bad "$1"; }

# Снимок расхода с управляемым числом и возрастом: ни одно из его значений не
# должно менять решение сторожа.
# $1 — процент ("none" = снимка нет), $2 — возраст в минутах.
set_usage() {
  python3 - "$HOME" "$1" "$2" <<'USAGE'
import json, os, sys, time
home, pct, age_min = sys.argv[1], sys.argv[2], float(sys.argv[3])
data = {} if pct == "none" else {"cachedUsageUtilization": {
    "fetchedAtMs": int((time.time() - age_min * 60) * 1000),
    "utilization": {"five_hour": {"utilization": int(pct), "resets_at": None}}}}
json.dump(data, open(os.path.join(home, ".claude.json"), "w"))
USAGE
}

make_project() {
  local dir="$WORK/$1"
  mkdir -p "$dir/docs/furca"
  printf '| id | блок | зависит от | статус | задача |\n|---|---|---|---|---|\n| T001 | api | — | todo | Работа |\n' > "$dir/tasks.md"
  echo '# Журнал' > "$dir/progress.md"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" add -A 2>/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  echo "$dir"
}

# $1 — каталог, $2 — текст брифа, $3 — роль ("none" = поля нет),
# $4 — имя инструмента.
call_guard() {
  local dir="$1" prompt="${2:-твои задачи: T001}" role="${3:-artifex}" tool="${4:-Agent}"
  local payload
  payload="$(python3 -c "
import json,sys
tool_input = {'prompt': sys.argv[2]}
if sys.argv[3] != 'none':
    tool_input['subagent_type'] = sys.argv[3]
print(json.dumps({'session_id':'s1','cwd':sys.argv[1],'hook_event_name':'PreToolUse',
                  'tool_name':sys.argv[4],'tool_input':tool_input}))" \
    "$dir" "$prompt" "$role" "$tool")"
  GUARD_OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"
}

echo "содержание волны: вне стройки сторожа не существует"

set_usage 10 0
p="$(make_project plain)"
call_guard "$p"
expect_silent "стройки нет — запуск агентов владельца не наше дело"

b="$(make_project build)"
python3 "$KEEP" --start "$b" > /dev/null
call_guard "$b" "твои задачи: T001" "artifex" "Bash"
expect_silent "не запуск агента — сторож молчит"

echo
echo "содержание волны: продуктовая задача проходит при любом снимке расхода"

# Перебор вместо одного значения: механизм, считавший ширину по этим числам,
# снят, и вернуться он не должен ни через «почти пусто», ни через «100%».
while read -r pct age case; do
  set_usage "$pct" "$age"
  call_guard "$b"
  expect_allow "$case — запуск блока разрешён"
done <<'CASES'
10 0 пустое_окно
99 0 свежий_снимок_выбранного_окна
100 2880 снимок_двухсуточной_давности
none 0 снимка_нет
CASES

set_usage 99 0
call_guard "$b"
if [[ "$GUARD_OUT" == *"ПУШ"* ]]; then ok "в разрешении потребован коммит и пуш после каждой задачи"; else bad "разрешение не говорит, чем держится прогресс"; fi
if [[ "$GUARD_OUT" == *"%"* ]]; then bad "сторож снова считает проценты лимита"; else ok "процента лимита в ответе нет"; fi

echo
echo "содержание волны: короткие роли волной не считаются"

for role in norma optio exploratio; do
  call_guard "$b" "твои задачи: T001" "$role"
  expect_silent "роль $role — не блок, сторож молчит"
done

echo
echo "содержание волны: блок-агент не запускается на одних служебных задачах"

c="$(make_project chores)"
python3 "$KEEP" --start "$c" > /dev/null
printf '| id | блок | зависит от | статус | задача |\n|---|---|---|---|---|\n| T010 | chores | — | todo | Планка числа тестов |\n| T011 | chores | — | todo | Срезать журналы блоков |\n| T012 | core | — | todo | Экран заполнения |\n' > "$c/tasks.md"

call_guard "$c" "твои задачи: T010, T011"
expect_deny "все задачи волны служебные — запуск отклонён"
if [[ "$GUARD_OUT" == *"chores"* ]]; then ok "в отказе названо, по какому признаку он вынесен"; else bad "отказ не называет причину"; fi

call_guard "$c" "твои задачи: T010, T012"
expect_allow "есть продуктовая задача — служебная едет вместе с ней"

call_guard "$c" "бриф без идентификаторов"
expect_allow "id задач в брифе нет — сторож не выдумывает"

call_guard "$c" "твои задачи: T777"
expect_allow "задачи нет в графе — не знаем, значит не запрещаем"

call_guard "$c" "твои задачи: T010, T011" "norma"
expect_silent "короткая роль на служебной задаче — это не волна"

call_guard "$c" "твои задачи: T010, T011" "none"
expect_deny "роль не названа — считается блоком, как раньше"

echo
echo "содержание волны: собой ничего не ломает"

set +e
printf 'мусор' | python3 "$GUARD" >/dev/null 2>&1
(( $? == 0 )) && ok "мусор на входе — выход 0" || bad "мусор валит сторожа"
set -e

echo
if (( failed )); then
  echo "ПРОВАЛЕНО: $failed, прошло: $passed"
  exit 1
fi
echo "PASS ($passed)"
