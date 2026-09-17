#!/usr/bin/env bash
set -uo pipefail

# Тесты ограничителя ширины волны. Четыре блок-агента, запущенные разом, сожгли
# общий лимит вчетверо быстрее одного и оборвались одновременно — каждый в шаге
# от сдачи, ни один не успел проверить работу (issue #76). Диспетчер заботится о
# портах и стендах, потому что конфликт ресурсов машины виден, а общий лимит
# сессии не виден никому.
#
# Ограничитель обязан быть скупым: он запрещает запуск работы, и ложный запрет
# останавливает стройку целиком. Поэтому вмешательство только вблизи лимита, и
# сначала словом, а не отказом.

FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$FURCA_HOME/hooks/guard-wave-width.py"
KEEP="$FURCA_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$GUARD" ]] || { echo "FAIL: нет файла ограничителя $GUARD"; exit 1; }

passed=0; failed=0

set_usage() {
  python3 - "$HOME" "$1" <<'USAGE'
import json, os, sys, time
home, pct = sys.argv[1], sys.argv[2]
data = {} if pct == "none" else {"cachedUsageUtilization": {
    "fetchedAtMs": int(time.time() * 1000),
    "utilization": {"five_hour": {"utilization": int(pct), "resets_at": None}}}}
json.dump(data, open(os.path.join(home, ".claude.json"), "w"))
USAGE
}

# Снимок с управляемым возрастом и временем сброса окна: ими проверяется, что
# ограничитель смотрит не только на число (#93).
# $1 — процент, $2 — возраст снимка в минутах, $3 — сдвиг сброса окна в минутах
# (отрицательный = окно уже сбросилось), "none" = поля нет.
set_usage_at() {
  python3 - "$HOME" "$1" "$2" "$3" <<'USAGE'
import json, os, sys, time
from datetime import datetime, timedelta, timezone
home, pct, age_min, reset_min = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
resets_at = None
if reset_min != "none":
    moment = datetime.now(timezone.utc) + timedelta(minutes=float(reset_min))
    # Снимок харнесса пишет время без пояса и в UTC — воспроизводим как есть.
    resets_at = moment.replace(tzinfo=None).isoformat()
data = {"cachedUsageUtilization": {
    "fetchedAtMs": int((time.time() - age_min * 60) * 1000),
    "utilization": {"five_hour": {"utilization": pct, "resets_at": resets_at}}}}
json.dump(data, open(os.path.join(home, ".claude.json"), "w"))
USAGE
}

call_guard() {
  local dir="$1" tool="${2:-Agent}" role="${3:-artifex}"
  local payload
  payload="$(python3 -c "
import json,sys
tool_input = {'prompt':'бриф'}
if sys.argv[3] != 'none':
    tool_input['subagent_type'] = sys.argv[3]
print(json.dumps({'session_id':'s1','cwd':sys.argv[1],'hook_event_name':'PreToolUse',
                  'tool_name':sys.argv[2],
                  'tool_input':tool_input}))" "$dir" "$tool" "$role")"
  GUARD_OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"
  GUARD_CODE=$?
}

# Волну обнуляем явно там, где проверяем именно её первый запуск: предыдущие
# блоки теста уже насчитали агентов, и без сброса проверялось бы не то.
reset_wave() {
  python3 - "$HOME" <<'RESET'
import json, os, sys, glob
for f in glob.glob(os.path.join(sys.argv[1], ".claude", "furca", "builds", "*.json")):
    d = json.load(open(f))
    d["wave_launches"] = []
    json.dump(d, open(f, "w"))
RESET
}

ok()   { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad()  { failed=$((failed+1)); printf '  FAIL %s — вывод: %s\n' "$1" "${GUARD_OUT:0:200}"; }
expect_deny()   { [[ "$GUARD_OUT" == *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_warn()   { [[ "$GUARD_OUT" == *"additionalContext"* && "$GUARD_OUT" != *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_silent() { [[ -z "$GUARD_OUT" ]] && ok "$1" || bad "$1"; }

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

echo "ширина волны: вне стройки и вдали от лимита не вмешивается"

p="$(make_project plain)"
set_usage 99
call_guard "$p"
expect_silent "стройки нет — запуск агентов владельца не наше дело"

b="$(make_project build)"
python3 "$KEEP" --start "$b" > /dev/null

set_usage 10
call_guard "$b"
expect_silent "лимит далеко — волна любой ширины разрешена"
call_guard "$b"; call_guard "$b"; call_guard "$b"
expect_silent "четыре запуска подряд при пустом лимите — по-прежнему молчит"

set_usage none
call_guard "$b"
expect_silent "нет данных о лимите — не выдумываем ограничение"

echo
echo "ширина волны: близко к лимиту"

set_usage 75
call_guard "$b"
expect_warn "три четверти окна — предупреждение, но запуск разрешён"
if [[ "$GUARD_OUT" == *"75"* ]]; then ok "в предупреждении названа цифра расхода"; else bad "в предупреждении нет цифры"; fi

# На исходе окна первый агент волны ещё нужен: остановить стройку целиком —
# работа сторожа непрерывности, а не ограничителя ширины.
set_usage 88
reset_wave
call_guard "$b"
expect_warn "первый запуск волны на исходе лимита разрешён, но с предупреждением"
call_guard "$b"
expect_deny "второй запуск в той же волне на исходе лимита запрещён"
if [[ "$GUARD_OUT" == *"дожди"* || "$GUARD_OUT" == *"один"* ]]; then ok "в отказе сказано, что делать вместо этого"; else bad "отказ не говорит, что делать"; fi

echo
echo "ширина волны: волна кончилась — счёт заново"

python3 - "$HOME" <<'AGE'
import json, os, sys, glob, time
# Состаренные запуски: волна, начатая полчаса назад, давно кончилась.
for f in glob.glob(os.path.join(sys.argv[1], ".claude", "furca", "builds", "*.json")):
    d = json.load(open(f))
    d["wave_launches"] = [time.time() - 1800]
    json.dump(d, open(f, "w"))
AGE
call_guard "$b"
expect_warn "старые запуски не считаются текущей волной"

echo
echo "ширина волны: окно одно на все стройки"

# Пятичасовое окно подписки — одно на аккаунт, а стройки о нём договариваться не
# умеют: 15.09.2026 три стройки стартовали в одно окно и втроём выбрали его за
# пять часов, не дойдя ни одна до раздачи блоков (#105). Ограничитель обязан
# делить остаток на число живых строек, а не отдавать каждой целиком.
# Маркеры прошлых блоков этого файла живы и свежи — для ограничителя они такие
# же соседи, как настоящие стройки. Убираем, чтобы проверять именно счёт соседей,
# а не остатки предыдущих проверок.
rm -f "$HOME/.claude/furca/builds/"*.json
solo="$(make_project solo)"
python3 "$KEEP" --start "$solo" > /dev/null
set_usage 75
reset_wave
call_guard "$solo"
expect_warn "одна стройка, 75% — первый агент разрешён"
call_guard "$solo"
expect_warn "одна стройка, 75% — второй агент в пределах ширины"
call_guard "$solo"
expect_deny "одна стройка, 75% — третий агент сверх ширины"

neighbour="$(make_project neighbour)"
python3 "$KEEP" --start "$neighbour" > /dev/null
reset_wave
call_guard "$solo"
expect_warn "две стройки — первый агент разрешён"
[[ "$GUARD_OUT" == *"кроме этой идут"* ]] && ok "соседняя стройка названа в предупреждении" || bad "про соседнюю стройку не сказано"
call_guard "$solo"
expect_deny "две стройки делят окно — ширина вдвое уже"

# Стройка, с которой давно нет ни одного признака жизни, окно не тратит:
# сужать волну живой стройке из-за брошенного маркера значило бы наказывать за
# чужой забытый прогон.
python3 - "$HOME" "$neighbour" <<'STALE'
import json, os, sys, glob, time
from datetime import datetime, timedelta
old = (datetime.now() - timedelta(hours=4)).isoformat()
for f in glob.glob(os.path.join(sys.argv[1], ".claude", "furca", "builds", "*.json")):
    d = json.load(open(f))
    # Маркер хранит путь после resolve() (/private/var...), а фикстура знает его
    # как /var... — сравниваем по имени каталога, иначе состаривание промахнётся.
    if str(d.get("project", "")).rstrip("/").endswith("/" + os.path.basename(sys.argv[2])):
        d["started_at"] = old
        d["last_hold_at"] = old
        d["wave_launches"] = [time.time() - 4 * 3600]
        json.dump(d, open(f, "w"))
STALE
reset_wave
call_guard "$solo"
expect_warn "давно молчащая стройка окно не делит — первый агент"
call_guard "$solo"
expect_warn "давно молчащая стройка окно не делит — второй агент"

echo
echo "ширина волны: снимок расхода судится по возрасту, а не только по числу"

# 06.09.2026 ограничитель отменил уже запущенный блок по 85%, тогда как окно
# сбросилось десятью минутами раньше и было пустым: снимок в ~/.claude.json
# обновляется рывками и живёт дольше окна. Час работы ушёл на перезапуск (#93).
rm -f "$HOME/.claude/furca/builds/"*.json
fresh="$(make_project fresh)"
python3 "$KEEP" --start "$fresh" > /dev/null
set_usage_at 95 0 -5     # число страшное, но срок сброса окна уже прошёл
call_guard "$fresh"
expect_silent "окно со сброшенным сроком читается как пустое, а не как 95%"

set_usage_at 95 0 60     # то же число, но окно живое — ограничитель обязан вмешаться
call_guard "$fresh"
expect_warn "живое окно на 95% — предупреждение"

# Протухший снимок — это «неизвестно», а не «всё хорошо»: причина называется
# вслух. Но незнание не должно наказываться строже известного расхода: ошибка в
# протухшем снимке однонаправленная — он почти всегда показывает БОЛЬШЕ
# фактического, — поэтому ширина считается по числу из него, а не падает до
# одного блока. Раньше падала: на прогоне meridius 17.09.2026 так отклонялись
# короткие роли при запасе окна (#119).
rm -f "$HOME/.claude/furca/builds/"*.json
stale_p="$(make_project stale-usage)"
python3 "$KEEP" --start "$stale_p" > /dev/null
set_usage_at 10 90 120   # расход маленький, но снимку полтора часа
call_guard "$stale_p"
expect_warn "устаревший снимок: первый блок разрешён"
if [[ "$GUARD_OUT" == *"неизвест"* ]]; then ok "в предупреждении сказано, что расход неизвестен"; else bad "устаревший снимок выдан за известный"; fi
call_guard "$stale_p"
expect_warn "устаревший снимок с малым расходом: второй блок не душится"

# Устаревший снимок с большим числом — ширина по нему, то есть один блок.
set_usage_at 88 90 120
reset_wave
call_guard "$stale_p"
expect_warn "устаревший снимок на 88%: первый блок разрешён"
call_guard "$stale_p"
expect_deny "устаревший снимок на 88%: второй блок в той же волне запрещён"
if [[ "$GUARD_OUT" == *"мин"* ]]; then ok "в отказе назван возраст снимка"; else bad "отказ не говорит, почему расход неизвестен"; fi

echo
echo "ширина волны: меряется работа блоков, а не любой субагент"

# Роли несопоставимы по нагрузке: artifex — часы работы и свой стенд, optio —
# одна механическая задача, norma — сверка одного экрана. Считать их одним
# счётчиком значит делать сверку экрана недостижимой: картинки разрешены только
# norma, а запустить её нельзя, пока идёт блок. На meridius 17.09.2026 это
# оставило шесть задач сверки незакрытыми при готовых снимках (#119).
rm -f "$HOME/.claude/furca/builds/"*.json
roles_p="$(make_project roles)"
python3 "$KEEP" --start "$roles_p" > /dev/null
set_usage 88
reset_wave
call_guard "$roles_p"
expect_warn "блок-агент на исходе окна — первый разрешён"
call_guard "$roles_p"
expect_deny "второй блок-агент на исходе окна — по-прежнему запрещён"
call_guard "$roles_p" Agent norma
expect_silent "сверка экрана волной не считается — norma проходит при полной волне"
call_guard "$roles_p" Agent optio
expect_silent "исполнитель внутри блока волной не считается — optio проходит"
call_guard "$roles_p" Agent exploratio
expect_silent "исследователь волной не считается"
call_guard "$roles_p"
expect_deny "короткие роли счёт волны не сдвинули — блок-агент всё ещё запрещён"
call_guard "$roles_p" Agent none
expect_deny "роль не названа — считается блоком, как раньше"
call_guard "$roles_p" Agent general-purpose
expect_deny "незнакомая роль считается блоком: ограничитель сужается только по известным"

echo
echo "ширина волны: собой ничего не ломает"
set +e
printf 'мусор' | python3 "$GUARD" >/dev/null 2>&1
(( $? == 0 )) && ok "мусор на входе — выход 0" || bad "мусор валит ограничитель"
set -e
call_guard "$b" "Bash"
expect_silent "не запуск агента — ограничитель молчит"

echo
if (( failed == 0 )); then echo "PASS ($passed)"; else echo "ПРОВАЛЕНО: $failed, прошло: $passed"; exit 1; fi
