#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

VERSION="1.1.0"
UPDATE_URL="https://raw.githubusercontent.com/MakksSh/GeminiCLI2API-Termux-Autoinstall/refs/heads/main/cli2api.sh"
SCRIPT_PATH="$(readlink -f "$0")"

APP_NAME="geminicli2api"
REPO_URL="https://github.com/gzzhongqi/geminicli2api"
HOME_DIR="$HOME"
REPO_DIR="$HOME_DIR/$APP_NAME"

STATE_DIR="$HOME_DIR/.${APP_NAME}-installer"
STATE_FILE="$STATE_DIR/state.env"
LOG_FILE="$STATE_DIR/install.log"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1
exec 3>&1 4>&2

# -------- utils --------
c_reset=$'\033[0m'
c_blue=$'\033[36m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_red=$'\033[31m'

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "${c_blue}[$(ts)]${c_reset} $*"; }
ok()  { echo "${c_green}[$(ts)] OK:${c_reset} $*"; }
warn(){ echo "${c_yellow}[$(ts)] WARN:${c_reset} $*"; }
err() { echo "${c_red}[$(ts)] ERROR:${c_reset} $*" >&2; }

die() { err "$*"; exit 1; }

ask_yes_no() {
  local prompt="$1" ans
  while true; do
    read -r -p "$prompt [y/n]: " ans
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Введи y или n." ;;
    esac
  done
}

# -------- state --------
DONE_STEP=0
PROJECT_ID_SAVED=""
USE_VENV=1

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
  DONE_STEP="${DONE_STEP:-0}"
  PROJECT_ID_SAVED="${PROJECT_ID_SAVED:-}"
  USE_VENV="${USE_VENV:-1}"
}

save_state() {
  cat > "$STATE_FILE" <<EOF
DONE_STEP=$DONE_STEP
PROJECT_ID_SAVED=$(printf "%q" "$PROJECT_ID_SAVED")
USE_VENV=$USE_VENV
EOF
}

set_done() {
  DONE_STEP="$1"
  save_state
}

on_error() {
  local line="$1" cmd="$2"
  err "Падение на строке $line: $cmd"
  err "Последний завершённый шаг: DONE_STEP=$DONE_STEP"
  err "Перезапусти этот же скрипт — продолжит с нужного места."
  err "Если ошибка сохраняется — свяжись с автором скрипта: https://t.me/Maks_Sh"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

run_step() {
  local step="$1" title="$2"
  if (( DONE_STEP >= step )); then
    log "Шаг $step пропущен (уже выполнен): $title"
    return 0
  fi
  log "=== Шаг $step: $title ==="
  "$3"
  ok "Шаг $step завершён: $title"
  set_done "$step"
}

# -------- self-update --------
check_self_update() {
  [[ " $* " == *" --no-update "* ]] && return 0

  log "Проверка обновлений скрипта..."

  local remote_version
  remote_version=$(curl -sL --connect-timeout 5 "$UPDATE_URL" | grep -m1 -oP '^VERSION="\K[^"]+' || true)

  if [[ -z "$remote_version" ]]; then
    warn "Не удалось получить информацию о версии с сервера."
    return 0
  fi

  if [[ "$remote_version" != "$VERSION" ]]; then
    log "Доступна новая версия скрипта: $remote_version (текущая: $VERSION)"
    if ask_yes_no "Обновить скрипт сейчас?"; then
      do_self_update
    fi
  else
    log "Скрипт актуален (v$VERSION)."
  fi
}

do_self_update() {
  local script_path
  script_path="$(readlink -f "$0")"
  local tmp_file
  tmp_file=$(mktemp "$STATE_DIR/cli2api.sh.XXXXXX")
  log "Загрузка обновления..."

  if curl -sL --connect-timeout 10 "$UPDATE_URL" -o "$tmp_file"; then
    if [[ -s "$tmp_file" ]] && grep -q "VERSION=" "$tmp_file"; then
      chmod +x "$tmp_file"
      mv -f "$tmp_file" "$script_path"
      ok "Скрипт обновлён до версии $(grep -m1 -oP '^VERSION="\K[^"]+' "$script_path" || echo "unknown"). Перезапуск..."
      exec 1>&3 2>&4
      exec "$script_path" "$@"
    else
      err "Ошибка: Скачанный файл поврежден или некорректен."
      rm -f "$tmp_file"
      return 1
    fi
  else
    err "Ошибка при скачивании обновления."
    rm -f "$tmp_file"
    return 1
  fi
}

# -------- steps --------
step_10_pkg_update_upgrade() {
  cd "$HOME_DIR"
  command -v pkg >/dev/null 2>&1 || die "Команда pkg не найдена. Ты точно в Termux?"
  pkg update -y
  pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
}

step_20_pkg_install() {
  cd "$HOME_DIR"
  pkg install -y nano python rust git python-pip clang binutils python-cryptography
  if ! pkg install -y nodejs-lts; then
    warn "Пакет nodejs-lts не найден. Ставлю nodejs."
    pkg install -y nodejs
  fi
}

step_30_clone_or_update_repo() {
  cd "$HOME_DIR"
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Репозиторий уже существует. Обновляю (git pull --ff-only)."
    git -C "$REPO_DIR" fetch --all
    git -C "$REPO_DIR" pull --ff-only || warn "git pull не прошёл (возможно, локальные изменения). Продолжаю."
  else
    if [[ -d "$REPO_DIR" ]]; then
      warn "Найдена папка $REPO_DIR без .git (похоже на битую установку). Удаляю."
      rm -rf "$REPO_DIR"
    fi
    git clone "$REPO_URL" "$REPO_DIR"
  fi
}

step_40_fix_requirements() {
  cd "$REPO_DIR"
  [[ -f "requirements.txt" ]] || die "requirements.txt не найден в $REPO_DIR"

  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN{ }
    /^pydantic([<>=!~].*)?$/ { next }
    { print }
    END{ print "pydantic<2.0" }
  ' requirements.txt > "$tmp"
  mv "$tmp" requirements.txt

  log "requirements.txt обновлён: pydantic<2.0 гарантирован."
}

step_50_install_python_deps() {
  cd "$REPO_DIR"

  local py="python"
  if (( USE_VENV == 1 )); then
    if [[ ! -d ".venv" ]]; then
      log "Создаю виртуальное окружение .venv"
      if ! python -m venv --system-site-packages .venv; then
        warn "Не удалось создать venv. Переключаюсь на глобальный pip."
        USE_VENV=0
        save_state
      fi
    fi
  fi

  if (( USE_VENV == 1 )); then
    py="$REPO_DIR/.venv/bin/python"
    log "Использую venv: $py"
  else
    py="python"
    log "Использую глобальный python/pip"
  fi

  "$py" -m pip install -r requirements.txt
  log "Python зависимости установлены."
}

step_60_setup_env() {
  cd "$REPO_DIR"
  [[ -f ".env" ]] || {
    [[ -f ".env.example" ]] || die ".env.example не найден — не из чего создать .env"
    cp -f ".env.example" ".env"
    log "Создан .env из .env.example"
  }

  if grep -qE '^[[:space:]]*#?[[:space:]]*GOOGLE_CLOUD_PROJECT=' .env; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*GOOGLE_CLOUD_PROJECT=.*|GOOGLE_CLOUD_PROJECT=$PROJECT_ID_SAVED|g" .env
    log "GOOGLE_CLOUD_PROJECT обновлён в .env"
  else
    {
      echo ""
      echo "GOOGLE_CLOUD_PROJECT=$PROJECT_ID_SAVED"
    } >> .env
    log "GOOGLE_CLOUD_PROJECT добавлен в конец .env"
  fi
}

step_70_run_app() {
  cd "$REPO_DIR"

  pids="$(pgrep -f "$HOME/geminicli2api/.*run\.py" || true)"
  if [[ -n "${pids:-}" ]]; then
    warn "Найден запущенный geminicli2api (PID: $pids) — останавливаю"
    kill $pids 2>/dev/null || true
    sleep 3
    kill -9 $pids 2>/dev/null || true
  fi

  local py="python"
  if (( USE_VENV == 1 )) && [[ -x "$REPO_DIR/.venv/bin/python" ]]; then
    py="$REPO_DIR/.venv/bin/python"
  fi

  log "Запускаю geminicli2api: $py run.py"
  log "Важно: эту сессию оставь открытой. Остановить cli можно Ctrl+C."
  log "Дальше открой новую сессию Termux и запускай таверну там. Потяни слева экрана вправо, кнопка New Session."
  log "При первом запуске geminicli2api появится ссылка для авторизации."
  log "Скопируй ссылку и открой в браузере, авторизуйся с аккаунтом айди проекта от которого указал вначале."
  log "Затем вернись в Termux и убедись, что всё успешно запустилось."
  log "Если скрипт был полезен - буду признателен за подписку: https://t.me/btwiusesillytavern"

  exec 1>&3 2>&4
  PYTHONUNBUFFERED=1 "$py" run.py
}

# -------- main --------
main() {
  local arg_pid=""
  local do_reset=0
  local no_update=0

  for arg in "$@"; do
    case "$arg" in
      --reset)
        do_reset=1
        ;;
      --no-update)
        no_update=1
        ;;
      *)
        arg_pid="$arg"
        ;;
    esac
  done

  if (( do_reset == 1 )); then
    warn "ВНИМАНИЕ: Выбран ПОЛНЫЙ СБРОС (--reset)."
    if ask_yes_no "Это удалит все файлы приложения и настройки ($REPO_DIR и $STATE_DIR). Продолжить?"; then
      log "Выполняю сброс..."
      exec 1>&3 2>&4
      rm -rf "$REPO_DIR" "$STATE_DIR"
      
      mkdir -p "$STATE_DIR"
      touch "$LOG_FILE"
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      DONE_STEP=0
      PROJECT_ID_SAVED=""
      USE_VENV=1
      
      ok "Все данные удалены. Начинаю установку заново."
    else
      log "Сброс отменён."
    fi
  fi

  load_state
  check_self_update "$@"

  local first_run=0
  [[ -f "$STATE_FILE" ]] || first_run=1

  if (( first_run == 1 )) && [[ -d "$REPO_DIR" ]]; then
    warn "Обнаружена папка $REPO_DIR"
    if ask_yes_no "Сделать ПОЛНУЮ переустановку (удалить папку, сделать update/upgrade/install и поставить заново)?"; then
      log "Удаляю $REPO_DIR"
      rm -rf "$REPO_DIR"
      DONE_STEP=0
      PROJECT_ID_SAVED=""
      USE_VENV=1
      save_state
      ok "Состояние сброшено. Начинаю установку с нуля."
    else
      log "Ок, без полной переустановки. Буду продолжать/чинить по месту."
    fi
  fi

  if [[ -z "${PROJECT_ID_SAVED}" ]]; then
    local pid="$arg_pid"
    if [[ -z "$pid" ]]; then
      read -r -p "Введите GOOGLE_CLOUD_PROJECT (ID проекта): " pid
    fi
    pid="${pid//[[:space:]]/}"
    [[ -n "$pid" ]] || die "GOOGLE_CLOUD_PROJECT пустой — так не пойдёт."
    PROJECT_ID_SAVED="$pid"
    save_state
    ok "PROJECT_ID сохранён: $PROJECT_ID_SAVED"
  else
    ok "PROJECT_ID уже сохранён: $PROJECT_ID_SAVED"
    if [[ -n "$arg_pid" && "$arg_pid" != "$PROJECT_ID_SAVED" ]]; then
      warn "Передан новый PROJECT_ID, обновляю: $arg_pid"
      PROJECT_ID_SAVED="$arg_pid"
      
      if (( DONE_STEP >= 60 )); then
        log "Сбрасываю прогресс до шага 55 для обновления .env."
        DONE_STEP=55
      fi

      if [[ -f "$REPO_DIR/oauth_creds.json" ]]; then
        log "Удаляю старый oauth_creds.json для переавторизации."
        rm -f "$REPO_DIR/oauth_creds.json"
      fi

      save_state
    fi
  fi

  run_step 10 "pkg update && pkg upgrade" step_10_pkg_update_upgrade
  run_step 20 "pkg install зависимостей" step_20_pkg_install
  run_step 30 "Клонирование/обновление репозитория" step_30_clone_or_update_repo
  run_step 40 "Правка requirements.txt (pydantic<2.0)" step_40_fix_requirements
  run_step 50 "pip install -r requirements.txt" step_50_install_python_deps
  run_step 60 "Создание/правка .env (GOOGLE_CLOUD_PROJECT)" step_60_setup_env

  log "=== Финал: запуск приложения ==="
  step_70_run_app
}

main "$@"
