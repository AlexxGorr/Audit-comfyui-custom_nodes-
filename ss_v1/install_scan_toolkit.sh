#!/usr/bin/env bash
# =============================================================================
# install_scan_toolkit.sh — установка сканера ComfyUI-нод на новом компьютере
# =============================================================================
# Использование:
#   1. Скопируй всю папку (со scan.sh, scan_inner.sh, README.md) на новый ПК.
#   2. Перейди в неё в WSL.
#   3. bash install_scan_toolkit.sh
# =============================================================================

# --- Самозащита от CRLF ---
if grep -q $'\r' "$0" 2>/dev/null; then
    tr -d '\r' < "$0" > "$0.tmp" && mv "$0.tmp" "$0"
    chmod +x "$0"
    echo "Self-fix: CRLF -> LF. Перезапуск..."
    exec bash "$0" "$@"
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '%s\n' "$*"; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

log "================================================================"
log "  Установка ComfyUI Custom Nodes Scanner"
log "================================================================"
log ""

# --- 1. Проверка базовых требований ---
log "[1/8] Проверка окружения..."

if ! command -v docker >/dev/null 2>&1; then
    err "Docker не найден. Включи WSL-интеграцию в Docker Desktop."
    err "Настройки -> Resources -> WSL Integration -> Ubuntu = ON"
    exit 1
fi
log "  OK docker доступен"

if ! docker ps >/dev/null 2>&1; then
    err "Docker daemon не запущен. Открой Docker Desktop и дождись полной загрузки."
    exit 1
fi
log "  OK docker daemon работает"

# --- 2. Проверка файлов toolkit ---
log ""
log "[2/8] Проверка файлов сканера..."

for f in scan.sh scan_inner.sh; do
    if [ ! -f "$f" ]; then
        err "Файл не найден: $f"
        err "Убедись, что install_scan_toolkit.sh лежит в одной папке с scan.sh и scan_inner.sh"
        exit 1
    fi
    log "  OK $f найден"
done

# --- 3. Права на исполнение ---
log ""
log "[3/8] Установка прав на исполнение..."

chmod +x scan.sh
chmod +x scan_inner.sh
log "  OK chmod +x scan.sh"
log "  OK chmod +x scan_inner.sh"

# --- 4. Проверка переводов строк (CRLF) ---
log ""
log "[4/8] Проверка переводов строк..."

for f in scan.sh scan_inner.sh; do
    if grep -q $'\r' "$f" 2>/dev/null; then
        warn "  Файл $f имеет CRLF. Конвертирую в LF..."
        tr -d '\r' < "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        log "  OK $f -> LF"
    else
        log "  OK $f (LF)"
    fi
done

# --- 5. Проверка синтаксиса bash ---
log ""
log "[5/8] Проверка синтаксиса..."

for f in scan.sh scan_inner.sh; do
    if bash -n "$f" 2>/dev/null; then
        log "  OK $f"
    else
        err "  Синтаксис $f невалиден!"
        err "  Возможно, файл повреждён при копировании."
        exit 1
    fi
done

# --- 6. Поиск контейнера ComfyUI ---
log ""
log "[6/8] Поиск контейнера ComfyUI..."

CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i "comfy" | head -n1)

if [ -z "$CONTAINER_NAME" ]; then
    err "Контейнер ComfyUI не найден."
    err "Запусти его: cd <папка с docker-compose.yml> && docker compose up -d"
    exit 1
fi
log "  OK Найден контейнер: $CONTAINER_NAME"

if ! docker exec "$CONTAINER_NAME" test -d /root/ComfyUI/custom_nodes 2>/dev/null; then
    err "Внутри контейнера нет /root/ComfyUI/custom_nodes"
    err "Проверь конфигурацию контейнера:"
    err "  docker exec $CONTAINER_NAME ls /root/ComfyUI/"
    exit 1
fi
log "  OK Внутри есть /root/ComfyUI/custom_nodes"

# --- 7. Обновление имени контейнера в scan.sh (если нужно) ---
log ""
log "[7/8] Настройка имени контейнера..."

CURRENT_CONTAINER=$(grep -oP 'CONTAINER="\$\{COMFY_CONTAINER:-\K[^}]+' scan.sh 2>/dev/null || echo "")

if [ "$CURRENT_CONTAINER" = "$CONTAINER_NAME" ]; then
    log "  OK Имя контейнера уже правильное: $CONTAINER_NAME"
else
    log "  Заменяю '$CURRENT_CONTAINER' -> '$CONTAINER_NAME' в scan.sh..."
    sed -i "s|CONTAINER=\"\${COMFY_CONTAINER:-[^}]*}\"|CONTAINER=\"\${COMFY_CONTAINER:-$CONTAINER_NAME}\"|" scan.sh
    log "  OK Обновлено"
fi

# --- 8. Проверка запуска ---
log ""
log "[8/8] Проверка запуска сканера..."

if bash scan.sh --help >/dev/null 2>&1; then
    log "  OK scan.sh работает"
else
    err "  scan.sh не запускается. Пришли вывод: bash scan.sh --help"
    exit 1
fi

# --- Финальная проверка: --list ---
log ""
log "Проверка --list..."
NODE_COUNT=$(bash scan.sh --list 2>/dev/null | grep -c "  [A-Za-z]" || echo 0)
log "  Найдено нод: $NODE_COUNT"

# --- Готово ---
log ""
log "================================================================"
log "  УСТАНОВКА ЗАВЕРШЕНА"
log "================================================================"
log ""
log "Следующие шаги:"
log ""
log "  1. Список нод:"
log "     bash scan.sh --list"
log ""
log "  2. Полный скан:"
log "     bash scan.sh --scan-all --stream"
log ""
log "  3. Только CRITICAL:"
log "     bash scan.sh --scan-all --threshold CRITICAL"
log ""
log "  4. Одна нода:"
log "     bash scan.sh --scan ComfyUI-Impact-Pack --stream"
log ""
log "  5. Просмотр отчёта (q — выход):"
log "     bash scan.sh --report"
log ""
log "  6. Справка:"
log "     bash scan.sh --help"
log ""
log "Документация: README.md"
log ""
