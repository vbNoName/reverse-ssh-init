#!/bin/sh
#
# setup_autossh.sh — настройка постоянного обратного SSH-туннеля на OpenWRT
#
# Запуск (на роутере):
#   sh <(wget -O - https://raw.githubusercontent.com/vbNoName/reverse-ssh-init/refs/heads/main/setup_autossh.sh) <user> <server_ip> [server_port] [remote_port]
#
# Пример:
#   sh <(wget -O - https://raw.githubusercontent.com/vbNoName/reverse-ssh-init/refs/heads/main/setup_autossh.sh) openwrt xxx.xxx.xx.xx 22 2222
#

set -e

SSH_DIR="/root/.ssh"
SSH_KEY="$SSH_DIR/id_dropbear"
AUTOSSH_CONFIG="/etc/config/autossh"
DROPBEAR_KEYS="/etc/dropbear/authorized_keys"

line() {
    echo "────────────────────────────────────────────────────────────"
}

die() {
    echo "❌ $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Использование: $0 <user> <server_ip> [server_port] [remote_port]

  user         Имя пользователя на сервере с постоянным IP
  server_ip    IP-адрес (или домен) сервера
  server_port  SSH-порт сервера           (по умолчанию: 22)
  remote_port  Порт туннеля на сервере     (по умолчанию: 2222)

Пример: $0 openwrt xxx.xxx.xx.xx 22 2222
EOF
}

# ── Аргументы ───────────────────────────────────────────────────────────────
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "❌ Не указаны обязательные параметры подключения." >&2
    echo >&2
    usage >&2
    exit 1
fi

SERVER_USER="$1"
SERVER_IP="$2"
SERVER_PORT="${3:-22}"
REMOTE_PORT="${4:-2222}"

line
echo "🚀 Настройка обратного SSH-туннеля"
line
echo "  Сервер       : ${SERVER_USER}@${SERVER_IP}:${SERVER_PORT}"
echo "  Порт туннеля : ${REMOTE_PORT} (на сервере) → 22 (на роутере)"
line

# ── 1. Пакеты ───────────────────────────────────────────────────────────────
echo "📦 Проверка пакетов..."

if command -v autossh >/dev/null 2>&1; then
    echo "  ✔ autossh уже установлен"
else
    echo "  ⬇ Устанавливаю autossh..."
    opkg update >/dev/null 2>&1 || die "Не удалось обновить список пакетов. Проверьте интернет."
    opkg install autossh || die "Не удалось установить autossh."
fi

# ── 2. Остановка текущего туннеля ───────────────────────────────────────────
if [ -f /etc/init.d/autossh ]; then
    echo "🔄 Останавливаю текущую службу autossh..."
    service autossh stop >/dev/null 2>&1 || true
    pkill autossh >/dev/null 2>&1 || true
fi

# ── 3. SSH-ключ ─────────────────────────────────────────────────────────────
if [ -f "$SSH_KEY" ]; then
    echo "🔑 SSH-ключ уже существует, переиспользую: $SSH_KEY"
else
    echo "🔑 Генерирую SSH-ключ Dropbear..."
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    dropbearkey -t rsa -s 2048 -f "$SSH_KEY" >/dev/null 2>&1 \
        || die "Не удалось сгенерировать ключ."
fi

PUBKEY=$(dropbearkey -y -f "$SSH_KEY" 2>/dev/null | grep '^ssh-' || true)
[ -n "$PUBKEY" ] || die "Не удалось прочитать публичный ключ."

# ── 4. Публичный ключ для сервера ───────────────────────────────────────────
echo
line
echo "👉 ПУБЛИЧНЫЙ КЛЮЧ РОУТЕРА"
line
echo "$PUBKEY"
line
echo "Добавьте его на сервере в файл:"
echo "  /home/${SERVER_USER}/.ssh/authorized_keys"
echo
echo "Быстрый способ — выполнить на сервере:"
echo "  echo '$PUBKEY' >> /home/${SERVER_USER}/.ssh/authorized_keys"
line
printf "Нажмите [Enter], когда ключ будет добавлен на сервер... "
read -r _ || true
echo

# ── 5. Ключ сервера для входа на роутер (опционально) ───────────────────────
echo
line
echo "🔐 КЛЮЧ СЕРВЕРА ДЛЯ ВХОДА НА РОУТЕР (необязательно)"
line
echo "Вставьте ПУБЛИЧНЫЙ ключ сервера (содержимое ~/.ssh/id_ed25519.pub),"
echo "чтобы заходить на роутер через туннель без пароля."
echo "Получить его на сервере: cat ~/.ssh/id_ed25519.pub"
echo
echo "Вход по паролю останется включённым — ключ только дополняет его."
echo "Чтобы пропустить этот шаг, просто нажмите [Enter]."
line
printf "Публичный ключ сервера: "
read -r SERVER_PUBKEY || SERVER_PUBKEY=""

case "$SERVER_PUBKEY" in
    "")
        echo "  ⏭  Пропущено — вход на роутер только по паролю."
        ;;
    ssh-*|ecdsa-*|sk-*)
        mkdir -p "$(dirname "$DROPBEAR_KEYS")"
        touch "$DROPBEAR_KEYS"
        chmod 600 "$DROPBEAR_KEYS"
        if grep -qF "$SERVER_PUBKEY" "$DROPBEAR_KEYS" 2>/dev/null; then
            echo "  ✔ Такой ключ уже есть в $DROPBEAR_KEYS"
        else
            echo "$SERVER_PUBKEY" >> "$DROPBEAR_KEYS"
            echo "  ✔ Ключ добавлен в $DROPBEAR_KEYS"
        fi
        # Пароль оставляем разрешённым: вход по ключу — опция, а не замена.
        uci -q set dropbear.@dropbear[0].PasswordAuth='on' || true
        uci -q set dropbear.@dropbear[0].RootPasswordAuth='on' || true
        uci -q commit dropbear || true
        service dropbear reload >/dev/null 2>&1 || true
        echo "  ✔ Вход по паролю оставлен включённым"
        ;;
    *)
        echo "  ⚠️  Не похоже на публичный SSH-ключ — шаг пропущен."
        echo "     Ключ можно добавить позже вручную:"
        echo "     echo 'ssh-ed25519 AAAA...' >> $DROPBEAR_KEYS"
        ;;
esac
echo

# ── 6. Конфигурация autossh ─────────────────────────────────────────────────
echo "⚙️  Записываю конфигурацию $AUTOSSH_CONFIG..."
cat > "$AUTOSSH_CONFIG" <<EOF
config autossh
	option cls '0'
	option monitor '0'
	option poll '60'
	option gatetime '30'
	option ssh '-i $SSH_KEY -N -y -R $REMOTE_PORT:localhost:22 -p $SERVER_PORT $SERVER_USER@$SERVER_IP'
EOF

# ── 7. Доверие хосту (known_hosts) ──────────────────────────────────────────
echo "🔒 Добавляю сервер в known_hosts..."
dbclient -y -i "$SSH_KEY" -p "$SERVER_PORT" -N "${SERVER_USER}@${SERVER_IP}" >/dev/null 2>&1 &
DB_PID=$!
sleep 3
kill "$DB_PID" >/dev/null 2>&1 || true
wait "$DB_PID" 2>/dev/null || true

# ── 8. Запуск службы ────────────────────────────────────────────────────────
echo "▶️  Включаю автозапуск и запускаю autossh..."
service autossh enable
service autossh start

sleep 3
if pgrep autossh >/dev/null 2>&1; then
    STATUS="✅ служба autossh запущена"
else
    STATUS="⚠️  процесс autossh не найден — проверьте 'logread | grep autossh'"
fi

# ── Итог ────────────────────────────────────────────────────────────────────
echo
line
echo "🎉 Настройка завершена"
line
echo "  $STATUS"
echo
echo "  Подключение к роутеру — выполните на сервере ${SERVER_IP}:"
echo "    ssh root@localhost -p ${REMOTE_PORT}"
echo
echo "  Если публичный ключ сервера был добавлен — вход пройдёт без пароля,"
echo "  иначе роутер спросит пароль root (вход по паролю остаётся включённым)."
echo
echo "  Полезные команды на роутере:"
echo "    service autossh restart        — перезапуск туннеля"
echo "    logread | grep autossh         — логи туннеля"
line
