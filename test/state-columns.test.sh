#!/usr/bin/env bash
# Проверка целостности ловит лишнюю колонку в строке задачи (#196): неэкранированная
# труба в тексте сдвигает issue и этап, а зеркалирование молча пропускает задачу.
set -uo pipefail
FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

mutate() {  # mutate <dir> <новый текст задачи>
  python3 - "$1/tasks.md" "$2" <<'PY'
import sys
p, text = sys.argv[1], sys.argv[2]
s = open(p).read()
old = "Спроектировать схему БД для коротких ссылок"
assert old in s, "фикстура изменилась: нет строки для подмены (подмена не применилась)"
open(p, "w").write(s.replace(old, text, 1))
PY
}

cp -R "$FURCA_HOME/test/fixtures/toy-project" "$WORK/bad"
mutate "$WORK/bad" 'схема /api/x|y'
out="$(bash "$FURCA_HOME/test/state-format.test.sh" "$WORK/bad" 2>&1)" && fail "сырая труба в тексте задачи прошла проверку"
[[ "$out" == *"колонок 8 вместо 7"* ]] || fail "отказ без внятной причины: $out"

cp -R "$FURCA_HOME/test/fixtures/toy-project" "$WORK/ok"
mutate "$WORK/ok" 'схема /api/x\|y и `a | b`'
bash "$FURCA_HOME/test/state-format.test.sh" "$WORK/ok" >/dev/null 2>&1 || fail "экранированная труба и труба в inline-коде ложно отклонены"
echo "PASS: state-columns"
