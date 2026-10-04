#!/usr/bin/env bash
# =============================================================================
# scan_inner.sh v2.3 — security scanner для ComfyUI custom_nodes
# =============================================================================
# Args: $1=root $2=whitelist $3=include_js(0/1)
# Events: NODE_START|NODE_END|NODE_SKIP|FILE_START|FILE_END|HIT|FILE_DONE|SUMMARY
# =============================================================================

set -uo pipefail

ROOT="${1:-/root/ComfyUI/custom_nodes}"
WHITELIST_FILE="${2:-}"
INCLUDE_JS="${3:-0}"
NODE_ROOT="/root/ComfyUI/custom_nodes"

FILE_IS_LOCAL=0

is_test_file() {
    case "$1" in
        tests/*|test/*|examples/*|example/*|dev/*|docs/*) return 0 ;;
        */tests/*|*/test/*|*/examples/*|*/example/*|*/dev/*|*/docs/*) return 0 ;;
        *) return 1 ;;
    esac
}

is_install_file() {
    case "$1" in
        setup.py|*/setup.py|install.py|*/install.py|*.bat|*.cmd|*.ps1) return 0 ;;
        *) return 1 ;;
    esac
}

classify() {
    local line="$1"
    local file="$2"
    local t="${line#"${line%%[![:space:]]*}"}"

    [ -z "$t" ] && return 0

    # --- явные исключения ---
    # Определение метода def exec(...) — не вызов
    if [[ "$t" =~ ^[[:space:]]*def[[:space:]]+exec\( ]]; then
        return 0
    fi
    # .eval() — метод PyTorch
    [[ "$t" =~ [a-zA-Z0-9_\)\]]\.eval\( ]] && return 0
    # literal_eval — безопасно
    [[ "$t" =~ literal_eval ]] && return 0
    # import urllib.request без вызова
    if [[ "$t" =~ ^[[:space:]]*(from[[:space:]]+urllib|import[[:space:]]+urllib) ]] && ! [[ "$t" =~ urlopen|Request ]]; then
        return 0
    fi
    # sys.path.insert с __file__/dirname/abspath/_dir/_path
    if [[ "$t" =~ sys\.path\.insert ]] && [[ "$t" =~ (__file__|dirname|abspath|_dir|_path|_root|_folder) ]]; then
        return 0
    fi
    # pip install в комментарии
    if [[ "$t" =~ ^[[:space:]]*# ]] && [[ "$t" =~ pip[[:space:]]+install ]]; then
        return 0
    fi
    # os.system('color') — Windows-команда
    if [[ "$t" =~ os\.system\([\"\']color[\"\']\) ]]; then
        return 0
    fi

    # --- локальный файл: сетевые вызовы игнорируем ---
    if [ "$FILE_IS_LOCAL" = "1" ]; then
        if [[ "$t" =~ requests\.(get|post|put|delete|patch)\( ]] || [[ "$t" =~ urllib\.request ]]; then
            return 0
        fi
    fi

    # ==================== CRITICAL ====================
    # exec + base64 — реальная обфускация
    if [[ "$t" =~ exec\( ]] && echo "$t" | grep -q base64; then
        echo "CRITICAL|exec() + base64 - обфусцированная нагрузка."
        return
    fi
    # __import__('os').system
    if [[ "$t" =~ __import__.*os.*\.system ]]; then
        echo "CRITICAL|Обфусцированный os.system через __import__."
        return
    fi

    # exec() — но только если не установочный файл
    if [[ "$t" =~ (^|[^.[:alnum:]_])exec\( ]]; then
        if is_test_file "$file"; then
            echo "INFO|exec() в тестовом файле."
        elif is_install_file "$file"; then
            echo "ADMIN|exec() в установочном скрипте."
        else
            echo "CRITICAL|exec() - динамическое исполнение кода."
        fi
        return
    fi

    # os.system / os.popen / subprocess / pty.spawn
    if [[ "$t" =~ (os\.system|os\.popen|subprocess\.|pty\.spawn)\( ]]; then
        if is_install_file "$file"; then
            echo "ADMIN|Вызов внешнего процесса в установочном скрипте."
        else
            echo "CRITICAL|Вызов внешнего процесса."
        fi
        return
    fi

    # pickle.loads / marshal.loads
    if [[ "$t" =~ (pickle\.loads|marshal\.loads|shelve\.open)\( ]]; then
        if is_test_file "$file"; then
            echo "INFO|Опасная десериализация в тестовом файле."
        elif [[ "$t" =~ (recv|buffer|sock|pipe|conn|tobytes) ]]; then
            echo "WARNING|pickle.loads из сети/буфера (distributed)."
        else
            echo "CRITICAL|Опасная десериализация (pickle/marshal)."
        fi
        return
    fi

    # ctypes.CDLL — но если libc/libcudart/nvrtc — это GPU-штатно
    if [[ "$t" =~ ctypes\.(CDLL|cdll\.LoadLibrary) ]]; then
        if [[ "$t" =~ (libcudart|libcuda|libc\.so|nvrtc|libcublas|libcudnn) ]]; then
            echo "WARNING|Загрузка системной библиотеки (штатно для GPU)."
        else
            echo "CRITICAL|Загрузка нативных библиотек через ctypes."
        fi
        return
    fi

    # os.exec* — ADMIN в routes/manager/server
    if [[ "$t" =~ os\.exec(v|ve|vp|vpe)?\( ]]; then
        if [[ "$file" =~ routes\.py$ ]] || [[ "$file" =~ manager ]] || [[ "$file" =~ server\.py$ ]]; then
            echo "ADMIN|Перезапуск процесса (штатно для менеджера нод)."
        else
            echo "CRITICAL|Подмена процесса через os.exec*."
        fi
        return
    fi

    # ==================== ADMIN ====================
    if [[ "$t" =~ sys\.exit\( ]]; then
        if is_test_file "$file"; then
            return 0
        else
            echo "INFO|sys.exit() в CLI-скрипте."
        fi
        return
    fi
    if [[ "$t" =~ os\.kill\( ]] || [[ "$t" =~ shutil\.rmtree ]]; then
        if is_test_file "$file"; then
            return 0
        fi
        echo "ADMIN|Административная операция."
        return
    fi

    # ==================== WARNING ====================
    if [[ "$t" =~ requests\.(post|put|delete|patch)\( ]]; then
        echo "WARNING|HTTP-запрос на внешний хост (POST/PUT/DELETE)."
        return
    fi
    if [[ "$t" =~ requests\.get\( ]]; then
        echo "WARNING|HTTP GET на внешний хост."
        return
    fi
    if [[ "$t" =~ urllib\.request\.(urlopen|Request) ]]; then
        echo "WARNING|HTTP-запрос через urllib."
        return
    fi
    if [[ "$t" =~ socket\.socket\( ]] || [[ "$t" =~ socket\.connect\( ]]; then
        echo "WARNING|Raw-сокеты (часто distributed inference)."
        return
    fi
    if [[ "$t" =~ sys\.path\.insert ]]; then
        echo "WARNING|Модификация sys.path (нестандартная)."
        return
    fi
    if [ "${#t}" -gt 500 ] && ! echo "$t" | grep -q " "; then
        echo "WARNING|Длинная строка без пробелов - возможна обфускация."
        return
    fi

    # ==================== INFO ====================
    if [[ "$t" =~ importlib\.import_module ]]; then
        echo "INFO|Динамический импорт через importlib."
        return
    fi

    return 0
}

is_wl() {
    [ -z "$WHITELIST_FILE" ] && return 1
    [ -f "$WHITELIST_FILE" ] || return 1
    grep -Fxq "$1" "$WHITELIST_FILE" 2>/dev/null
}

collect_files() {
    local dir="$1"
    local ext_args=(-name "*.py" -o -name "*.sh" -o -name "*.bat" -o -name "*.ps1")
    if [ "$INCLUDE_JS" = "1" ]; then
        ext_args+=(-o -name "*.js")
    fi
    find "$dir" -type f \( "${ext_args[@]}" \) \
        -not -path "*/.git/*" \
        -not -path "*/__pycache__/*" \
        -not -path "*/.venv/*" \
        -not -path "*/venv/*" \
        -not -path "*/node_modules/*" \
        -print0 2>/dev/null | sort -z
}

node_count=0
file_count=0
line_count=0
c=0; w=0; i=0; a=0

declare -a node_dirs=()
if [ "$ROOT" = "$NODE_ROOT" ]; then
    for d in "$NODE_ROOT"/*/; do
        [ -d "$d" ] && node_dirs+=("$d")
    done
else
    node_dirs=("$ROOT/")
fi

for node_dir in "${node_dirs[@]}"; do
    [ -d "$node_dir" ] || continue
    node_name="$(basename "$node_dir")"

    if is_wl "$node_name"; then
        echo "NODE_SKIP|$node_name"
        continue
    fi

    node_count=$((node_count + 1))
    echo "NODE_START|$node_name"

    while IFS= read -r -d "" f; do
        file_count=$((file_count + 1))
        # Всегда относительно NODE_ROOT — путь с именем ноды
        rel="${f#$NODE_ROOT/}"
        echo "FILE_START|$rel"

        if ! grep -Iq . "$f" 2>/dev/null; then
            echo "FILE_DONE|0"
            echo "FILE_END"
            continue
        fi

        FILE_IS_LOCAL=0
        if grep -qE '(127\.0\.0\.1|localhost|0\.0\.0\.0)' "$f" 2>/dev/null; then
            FILE_IS_LOCAL=1
        fi

        file_hits=0
        lineno=0
        while IFS= read -r line || [ -n "$line" ]; do
            lineno=$((lineno + 1))
            line_count=$((line_count + 1))

            res="$(classify "$line" "$rel")"
            [ -z "$res" ] && continue

            lvl="${res%%|*}"
            reason="${res#*|}"
            snippet="${line:0:160}"
            file_hits=$((file_hits + 1))

            case "$lvl" in
                CRITICAL) c=$((c+1)) ;;
                WARNING)  w=$((w+1)) ;;
                INFO)     i=$((i+1)) ;;
                ADMIN)    a=$((a+1)) ;;
            esac

            echo "HIT|$lvl|$rel:$lineno|$snippet|$reason"
        done < "$f"

        # Если hits были — 1, иначе — 0
        if [ "$file_hits" -gt 0 ]; then
            echo "FILE_DONE|1"
        else
            echo "FILE_DONE|0"
        fi
        echo "FILE_END"
    done < <(collect_files "$node_dir")

    echo "NODE_END|$node_name"
done

echo "SUMMARY|$node_count|$file_count|$line_count|$c|$w|$i|$a"
