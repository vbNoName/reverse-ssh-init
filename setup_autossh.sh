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

echo "🚀 Начинаю автоматическую настройку обратного туннеля..."

# 1. Обновление пакетов и установка autossh
echo "📦 Установка пакетов..."
opkg update && opkg install autossh nano
if [ $? -ne 0 ]; then
    echo "❌ Ошибка при установке пакетов. Проверьте интернет на роутере."
    exit 1
fi

# 2. Создание SSH ключа, если его еще нет
SSH_KEY="/root/.ssh/id_dropbear"
if [ ! -f "$SSH_KEY" ]; then
    echo "🔑 Генерация SSH-ключа Dropbear..."
    mkdir -p /root/.ssh
    dropbearkey -t rsa -f "$SSH_KEY"
else
    echo "ℹ️ SSH-ключ уже существует."
fi

# 3. Вывод публичного ключа для пользователя
echo "--------------------------------------------------------"
echo "👉 ИНСТРУКЦИЯ: Скопируйте строку ниже и добавьте её"
echo "на сервере в файл: /home/$SERVER_USER/.ssh/authorized_keys"
echo "--------------------------------------------------------"
dropbearkey -y -f "$SSH_KEY" | grep -E "^ssh-rsa"
echo "--------------------------------------------------------"

# Пауза, чтобы пользователь успел скопировать ключ и настроить сервер
printf "Нажмите [Enter] ПОСЛЕ ТОГО, как добавите этот ключ на сервер..."
read tmp

# 4. Настройка конфигурации autossh
echo "⚙️ Настройка конфигурации /etc/config/autossh..."

cat << EOF > /etc/config/autossh
config autossh
        option cls '0'
        option monitor '0'
        option poll '60'
        option gatetime '30'
        option ssh '-i /root/.ssh/id_dropbear -N -R ${REMOTE_PORT}:localhost:22 -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_IP}'
EOF

# 5. Включение автозапуска и старт службы
echo "🔄 Запуск и включение службы autossh..."
/etc/init.d/autossh enable
/etc/init.d/autossh restart

# 6. Проверка первого подключения для добавления сервера в known_hosts
echo "🔒 Выполняю тестовое подключение для верификации хоста."
echo "Если появится запрос '(y/n)', введите 'y' и нажмите Enter."
echo "Если подключение зависнет — значит, ключ на сервере настроен неверно."

# Запускаем интерактивный SSH-клиент dropbear к серверу, чтобы подтвердить fingerprint сервера
dbclient -i "$SSH_KEY" -p "$SERVER_PORT" "${SERVER_USER}@${SERVER_IP}" "exit"

echo "✅ Настройка успешно завершена!"
echo "Роутер будет всегда доступен на вашем сервере по команде: ssh root@localhost -p ${REMOTE_PORT}"
