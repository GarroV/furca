#!/usr/bin/env bash
set -uo pipefail

# Тесты шаблона `templates/state/check-ids.sh` — проверки уникальности номеров
# состояния, которая живёт в CI проекта (#165).
#
# Чего не видят остальные сторожа: две ветки, каждая дописала D326, влились
# одна за другой. Правка в сессии (`guard-state-ids.py`) смотрит в одну ветку,
# `state-format.test.sh` запускают из checkout'а FURCA, которого в CI проекта
# нет, а git строки слил без конфликта (decimus, 08.10.2026). Ссылки после такого
# слияния разрешаются, только ведут не в ту запись, — и ничего не краснеет.

FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$FURCA_HOME/templates/state/check-ids.sh"
FIXTURE="$FURCA_HOME/test/fixtures/toy-project"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$SCRIPT" ]] || { echo "FAIL: нет файла $SCRIPT"; exit 1; }

passed=0; failed=0
ok()  { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf '  FAIL %s — вывод: %s\n' "$1" "${OUT:0:300}"; }

# Свежая копия фикстуры: $1 — имя каталога в WORK.
fresh() {
  mkdir -p "$WORK/$1"
  cp -R "$FIXTURE/tasks.md" "$FIXTURE/docs" "$WORK/$1/"
  echo "$WORK/$1"
}

# $1 — скрипт, $2 — каталог проекта; пишет OUT и RC.
run_check() {
  OUT="$(cd "$2" && bash "$1" 2>&1)"
  RC=$?
}

echo "номера состояния: чистая фикстура"
p="$(fresh clean)"
run_check "$SCRIPT" "$p"
(( RC == 0 )) && ok "без дублей — выход 0" || bad "чистая фикстура отклонена"

echo
echo "номера состояния: дубль ловится и называется"
p="$(fresh dup)"
echo '| D326 | 2026-10-08 | Первое решение | почему | owner |' >> "$p/docs/furca/decisions.md"
echo '| D326 | 2026-10-08 | Второе решение | почему | auto |' >> "$p/docs/furca/decisions.md"
run_check "$SCRIPT" "$p"
(( RC != 0 )) && ok "дубль D326 в decisions.md — выход не ноль" || bad "дубль D326 пропущен"
[[ "$OUT" == *"D326"* && "$OUT" == *"decisions.md"* ]] \
  && ok "в сообщении названы файл и номер" || bad "в сообщении нет файла или номера"
[[ "$OUT" == *"Развести"* ]] && ok "в сообщении сказано, как чинить" || bad "в сообщении нет «Развести»"

p="$(fresh dup-t)"
tid="$(grep -oE '^\| *T[0-9]{3} *\|' "$p/tasks.md" | grep -oE 'T[0-9]{3}' | head -1)"
grep -E "^\| *${tid} *\|" "$p/tasks.md" | head -1 >> "$p/tasks.md"
run_check "$SCRIPT" "$p"
(( RC != 0 )) && [[ "$OUT" == *"$tid"* ]] && ok "дубль $tid в tasks.md — отказ с номером" || bad "дубль задачи пропущен"

echo
echo "номера состояния: закомментированный пример в счёт не идёт"
p="$(fresh comment)"
echo '<!-- | D327 | 2026-10-08 | Пример | пример | owner | -->' >> "$p/docs/furca/decisions.md"
echo '<!-- | D327 | 2026-10-08 | Пример | пример | owner | -->' >> "$p/docs/furca/decisions.md"
run_check "$SCRIPT" "$p"
(( RC == 0 )) && ok "дубль внутри <!-- --> — выход 0" || bad "комментарий посчитан дублем"

echo
echo "номера состояния: файлов нет — не ошибка; пути переопределяются"
mkdir -p "$WORK/empty"
run_check "$SCRIPT" "$WORK/empty"
(( RC == 0 )) && ok "нет ни одного файла — выход 0" || bad "пустой проект отклонён"
p="$(fresh args)"
printf '| id |\n| D001 |\n| D001 |\n' > "$p/my-decisions.md"
OUT="$(cd "$p" && bash "$SCRIPT" tasks.md docs/furca/questions.md my-decisions.md 2>&1)"; RC=$?
(( RC != 0 )) && [[ "$OUT" == *"D001"* ]] && ok "третий аргумент — свой файл решений" || bad "аргументы не работают"

echo
echo "номера состояния: испорченная копия скрипта проверку не проходит"
# Копия без разбора id: на дубле она обязана молчать — а значит, тесты выше
# её ловят. Порча проверяется на применимость: подмена, не изменившая файл,
# сделала бы негативный прогон ложно зелёным.
BROKEN="$WORK/check-ids-broken.sh"
sed 's/uniq -d/uniq -u/' "$SCRIPT" > "$BROKEN"
if cmp -s "$SCRIPT" "$BROKEN"; then
  OUT="порча не применилась"; bad "негативный прогон: подмена ничего не изменила"
else
  p="$(fresh broken)"
  echo '| D326 | 2026-10-08 | Первое | почему | owner |' >> "$p/docs/furca/decisions.md"
  echo '| D326 | 2026-10-08 | Второе | почему | auto |' >> "$p/docs/furca/decisions.md"
  run_check "$BROKEN" "$p"
  if (( RC == 0 )) || [[ "$OUT" != *"D326"* ]]; then
    ok "испорченная копия не называет D326 — проверка выше её ловит"
  else
    bad "испорченная копия всё ещё ловит дубль"
  fi
fi

echo
if (( failed )); then
  echo "ПРОВАЛЕНО: $failed, прошло: $passed"
  exit 1
fi
echo "PASS ($passed)"
