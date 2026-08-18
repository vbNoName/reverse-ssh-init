#!/bin/sh

# Проверяем, переданы ли обязательные аргументы
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "❌ Ошибка: Не указаны параметры подключения!"
    echo "Использование: $0 <user> <server_ip> [server_port] [remote_port]"
    echo "Пример: $0 openwrt 192.168.1.50 2244 2222"
    exit 1
fi

SERVER_USER="$1"
SERVER_IP="$2"
SERVER_PORT="${3:-22}"       # Если порт не указан, используется 22
REMOTE_PORT="${4:-2222}"     # Если порт не указан, используется 2222

echo "🚀 Начинаю автоматическую настройку/обновление обратного туннеля..."

# 1. Проверка и установка пакетов
echo "📦 Проверка необходимых пакетов..."
PACKAGES_TO_INSTALL=""

# Проверяем nano
if command -v nano > /dev/null 2>&1; then
    echo "ℹ️ Текстовый редактор nano уже установлен."
else
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL nano"
fi

# Проверяем autossh
if [ -f "/etc/init.d/autossh" ] || command -v autossh > /dev/null 2>&1; then
    echo "ℹ️ Служба autossh уже установлена."
else
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL autossh"
fi

# Устанавливаем только отсутствующие пакеты
if [ ! -z "$PACKAGES_TO_INSTALL" ]; then
    echo "📥 Установка недостающих пакетов:$PACKAGES_TO_INSTALL..."
    opkg update && opkg install $PACKAGES_TO_INSTALL
    if [ $? -ne 0 ]; then
        echo "❌ Ошибка при установке пакетов. Проверьте интернет."
        exit 1
    fi
fi

# 2. Остановка старого туннеля (если скрипт запускается повторно)
if [ -f "/etc/init.d/autossh" ]; then
    echo "🔄 Останавливаю текущую службу autossh для обновления настроек..."
    service autossh stop > /dev/null 2>&1
    pkill autossh > /dev/null 2>&1
fi

# 3. Создание SSH ключа, если его еще нет
SSH_KEY="/root/.ssh/id_dropbear"
if [ ! -f "$SSH_KEY" ]; then
    echo "🔑 Генерация SSH-ключа Dropbear..."
    mkdir -p /root/.ssh
    dropbearkey -t rsa -f "$SSH_KEY"
else
    echo "ℹ️ SSH-ключ уже существует, переиспользован старый."
fi

# 4. Вывод публичного ключа для пользователя
echo "--------------------------------------------------------"
echo "👉 ИНСТРУКЦИЯ: Скопируйте строку ниже и убедитесь, что она"
echo "есть на сервере в файле: /home/$SERVER_USER/.ssh/authorized_keys"
echo "--------------------------------------------------------"
dropbearkey -y -f "$SSH_KEY" | grep -E "^ssh-rsa"
echo "--------------------------------------------------------"

printf "Нажмите [Enter] ПОСЛЕ ТОГО, как проверите ключ на сервере..."
read tmp

# 5. Перезапись конфигурации autossh
echo "⚙️ Обновление конфигурации /etc/config/autossh..."
# Флаг -y в параметрах ssh заставит autossh автоматически доверять серверу при первом старте
printf "config autossh\n        option cls '0'\n        option monitor '0'\n        option poll '60'\n        option gatetime '30'\n        option ssh '-i /root/.ssh/id_dropbear -N -y -R %s:localhost:22 -p %s %s@%s'\n" "$REMOTE_PORT" "$SERVER_PORT" "$SERVER_USER" "$SERVER_IP" > /etc/config/autossh

# 6. Включение автозапуска и запуск с новыми настройками
echo "🔄 Запуск службы autossh с новыми параметрами..."
service autossh enable
service autossh start

# 7. Проверка подключения (с флагом автоматического добавления в known_hosts)
echo "🔒 Выполняю автоматическое добавление сервера в trusted hosts..."
dbclient -y -i "$SSH_KEY" -p "$SERVER_PORT" -N "${SERVER_USER}@${SERVER_IP}" >/dev/null 2>&1 &
DB_PID=$!
sleep 2
kill $DB_PID > /dev/null 2>&1

echo "✅ Все настройки успешно применены!"

# Выводим финальный блок информации без кавычек во избежание конфликтов парсинга в ash
cat << 'INFO'
Роутер доступен на сервере. Для подключения выполните на сервере команду:
ssh root@localhost -p 2222
INFO
