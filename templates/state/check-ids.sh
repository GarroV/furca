#!/usr/bin/env bash
# Целостность номеров состояния: один номер T/Q/D — одна запись.
# Копия лежит в проекте как scripts/check-state-ids.sh и работает без FURCA:
# в CI проекта его checkout'а нет (см. skills/admissio, skills/ordo).
# Запуск из корня репозитория; пути можно переопределить аргументами:
#   check-state-ids.sh [tasks.md [questions.md [decisions.md]]]
# Строки считаются ровно как в test/state-format.test.sh: `| Xnnn |` в начале
# строки таблицы, закомментированные примеры <!-- | D001 | ... --> в счёт не идут.
set -euo pipefail

TASKS="${1:-tasks.md}"
QUESTIONS="${2:-docs/furca/questions.md}"
DECISIONS="${3:-docs/furca/decisions.md}"

status=0
for pair in "$TASKS:T" "$QUESTIONS:Q" "$DECISIONS:D"; do
  file="${pair%:*}" letter="${pair##*:}"
  [[ -f "$file" ]] || continue
  dup_ids="$(grep -oE "^\| *${letter}[0-9]{3} *\|" "$file" | grep -oE "${letter}[0-9]{3}" \
    | sort | uniq -d || true)"
  if [[ -n "$dup_ids" ]]; then
    status=1
    echo "FAIL: $file: один номер занят дважды: $(echo "$dup_ids" | tr '\n' ' ')"
    echo "      Две ветки взяли «следующий свободный» номер каждая, а git слил строки"
    echo "      без конфликта: ссылки на этот номер теперь ведут не в ту запись."
    echo "      Развести: более поздние записи переименовать в свободные номера и"
    echo "      обновить все ссылки на них (tasks.md, questions.md, decisions.md,"
    echo "      progress.md, CHANGELOG.md)."
  fi
done
exit "$status"
