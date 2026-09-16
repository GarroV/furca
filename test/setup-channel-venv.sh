#!/usr/bin/env bash
set -euo pipefail

# Поднимает окружение для тестов базы канала: venv с закреплёнными зависимостями
# из channel/bot/requirements.txt. Идемпотентно — повторный запуск ничего не ломает.
#
# Зачем отдельный скрипт: test/channel-db.test.sh намеренно fail-closed, и без
# зависимостей он падает. Пока подъём окружения был тремя командами из текста
# ошибки, полный прогон месяцами шёл 13/14, а тесты адресации канала (кто какие
# строки видит и помечает разобранными) не проверялись ни разу (#99).
#
# Переменные:
#   FURCA_CHANNEL_VENV   — куда ставить (по умолчанию ~/.claude/furca/channel-venv)
#   FURCA_CHANNEL_PYTHON — каким интерпретатором создавать venv

FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
REQ="$FURCA_HOME/channel/bot/requirements.txt"
VENV="${FURCA_CHANNEL_VENV:-$HOME/.claude/furca/channel-venv}"

[[ -f "$REQ" ]] || { echo "FAIL: нет $REQ"; exit 1; }

# Интерпретатор: aiogram требует >= 3.10, а системный python3 на macOS всё ещё
# 3.9 — venv на нём соберётся и упадёт только на установке, уже невнятно.
# Порядок предпочтения начинается с 3.12: на нём собран боевой образ канала
# (channel/bot/Dockerfile, python:3.12-slim), и тесты должны идти на том же.
pick_python() {
  local candidate
  for candidate in "${FURCA_CHANNEL_PYTHON:-}" python3.12 python3.13 python3.11 python3; do
    [[ -n "$candidate" ]] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

PYTHON="$(pick_python)" || {
  echo "FAIL: не нашёл Python >= 3.10 — aiogram ниже не ставится."
  echo "  Поставь его (brew install python@3.12) или укажи свой: FURCA_CHANNEL_PYTHON=/путь/к/python"
  exit 1
}

echo "Интерпретатор: $PYTHON ($("$PYTHON" -V 2>&1))"
echo "Каталог venv:  $VENV"

if [[ ! -x "$VENV/bin/python" ]]; then
  mkdir -p "$(dirname "$VENV")"
  "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -r "$REQ"

"$VENV/bin/python" -c 'import asyncpg, aiohttp, aiogram' || {
  echo "FAIL: зависимости поставлены, но не импортируются — окружение битое"
  exit 1
}

echo "Готово. Тесты базы канала теперь находят venv сами:"
echo "  bash test/channel-db.test.sh"
