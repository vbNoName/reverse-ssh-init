# Полное руководство по настройке обратного SSH-туннеля для OpenWRT

Эта инструкция описывает три способа организации удаленного доступа к роутеру OpenWRT, находящемуся за серым IP (NAT). Во всех сценариях роутер сам инициирует соединение и «пробрасывает» свой порт управления на сервер с постоянным IP-адресом.

---

## 🏗️ Общая подготовка инфраструктуры

Перед реализацией любого из способов необходимо выполнить базовую настройку сервера и роутера.

### Шаг 1. Подготовка сервера с постоянным IP-адресом

Чтобы сервер мог перенаправлять порты для обратного туннеля, измените настройки SSH-демона.

1. Откройте конфигурационный файл SSH-сервера:

   ```bash
   sudo nano /etc/ssh/sshd_config
   ```
2. Найдите и активируйте (удалите символ #, если он есть) следующие строки:

   ```text
   GatewayPorts yes
   AllowTcpForwarding yes
   ```
3. Перезапустите службу SSH:

   ```bash
   sudo systemctl restart ssh
   ```

### Шаг 2. Настройка авторизации по ключам (на OpenWRT)

Авторизация по паролю не подходит для автоматизации. Настроим SSH-ключи Dropbear.

1. Подключитесь к роутеру OpenWRT и сгенерируйте SSH-ключ:

   ```bash
   dropbearkey -t rsa -f ~/.ssh/id_dropbear
   ```
2. Выведите созданный публичный ключ на экран:

   ```bash
   dropbearkey -y -f ~/.ssh/id_dropbear
   ```
3. Скопируйте строку с ключом (начинается с ssh-rsa ...) и добавьте её на вашем сервере с постоянным IP-адресом в файл \~/.ssh/authorized_keys.

---

## 🛠️ Способ 1. Постоянный туннель (Всегда онлайн) — Рекомендуемый

Самый надежный подход. Роутер поднимает туннель при загрузке и поддерживает его 24/7. При обрыве связи утилита autossh автоматически переподключит туннель.

1. Установите необходимые пакеты на OpenWRT:

   ```bash
   opkg update && opkg install autossh
   ```
2. Откройте файл конфигурации autossh на роутере:

   ```bash
   nano /etc/config/autossh
   ```
3. Замените содержимое файла следующим конфигом:

   ```text
   config autossh
           option cls '0'
           option monitor '0'
           option poll '60'
           option gatetime '30'
           option ssh '-i /root/.ssh/id_dropbear -N -R 2222:localhost:22 -p 22 user@IP_СЕРВЕРА'
   ```

   Где user — имя пользователя на сервере, а IP\_СЕРВЕРА — его постоянный IP.
4. Включите автозапуск и запустите службу:

   ```bash
   /etc/init.d/autossh enable
   /etc/init.d/autossh start
   ```

Как подключиться к роутеру: Зайдите на сервер с постоянным IP по SSH и выполните:

```bash
ssh root@localhost -p 2222
```

---

## 🤖 Способ 2. Запуск туннеля через Telegram-бота (По запросу)

Туннель создается только после того, как вы отправите команду /start вашему персональному Telegram-боту.

1. Установите зависимости на OpenWRT:

   ```bash
   opkg update && opkg install curl ca-bundle autossh
   ```
2. Создайте файл скрипта /root/tg_bot.sh:

   ```bash
   touch /root/tg_bot.sh && chmod +x /root/tg_bot.sh
   nano /root/tg_bot.sh
   ```
3. Вставьте следующий код, указав свои данные (Токен бота и ваш личный Chat ID для безопасности):

   ```bash
   #!/bin/sh
   
   TOKEN="ВАШ_ТОКЕН_БОТА"
   MY_CHAT_ID="ВАШ_ЛИЧНЫЙ_CHAT_ID"
   SERVER_USER="user"                   
   SERVER_IP="IP_СЕРВЕРА"     
   REMOTE_PORT="2222"
   REMOTE_TARGET_PORT="22"                   
   
   OFFSET=0
   
   while true; do
       RESPONSE=$(curl -s "https://telegram.org")
       UPDATE_ID=$(echo "$RESPONSE" | grep -o '"update_id":[0-9]*' | tail -n 1 | cut -d: -f2)
       CHAT_ID=$(echo "$RESPONSE" | grep -o '"chat":{"id":[0-9\-]*' | tail -n 1 | cut -d: -f3)
       TEXT=$(echo "$RESPONSE" | grep -o '"text":"[^"]*' | tail -n 1 | cut -d'"' -f4)
   
       if [ ! -z "$UPDATE_ID" ]; then
           OFFSET=$((UPDATE_ID + 1))
   
           if [ "$CHAT_ID" = "$MY_CHAT_ID" ]; then
               if [ "$TEXT" = "/start" ]; then
                   curl -s -X POST "https://telegram.org" -d "chat_id=$CHAT_ID&text=Инициализирую туннель..."
                   if pgrep autossh > /dev/null; then
                       curl -s -X POST "https://telegram.org" -d "chat_id=$CHAT_ID&text=Туннель уже активен!"
                   else
                       autossh -M 0 -f -i /root/.ssh/id_dropbear -N -R ${REMOTE_PORT}:localhost:22 -p ${REMOTE_TARGET_PORT} ${SERVER_USER}@${SERVER_IP}
                       curl -s -X POST "https://telegram.org" -d "chat_id=$CHAT_ID&text=Туннель запущен. Порт: ${REMOTE_PORT}"
                   fi
               elif [ "$TEXT" = "/stop" ]; then
                   pkill autossh
                   pkill -f "dropbear"
                   curl -s -X POST "https://telegram.org" -d "chat_id=$CHAT_ID&text=Туннель остановлен."
               fi
           fi
       fi
       sleep 1
   done
   ```
4. Для настройки автозапуска бота добавьте в файл /etc/rc.local перед строкой exit 0:

   ```text
   /root/tg_bot.sh &
   ```

Как подключиться к роутеру: Отправьте боту команду /start, после чего подключитесь через сервер с постоянным IP командой ssh root@localhost -p 2222.

---

## 🚪 Способ 3. Подключение «по стуку» (Port Knocking)

Роутер находится в режиме ожидания. Вы отправляете скрытый пакетный сигнал («стук») на порты сервера с постоянным IP, сервер создает триггер, а роутер, проверяя сервер по расписанию, автоматически поднимает туннель.

### Настройка на стороне сервера с постоянным IP:

1. Установите демон knockd:

   ```bash
   sudo apt update && sudo apt install knockd
   ```
2. В файле /etc/knockd.conf задайте секретную последовательность портов (например: 7000, 8000, 9000):

   ```text
   [options]
           UseSyslog
   
   [openSSH]
           sequence    = 7000,8000,9000
           seq_timeout = 5
           start_command = echo "open" > /tmp/router_trigger
           cmd_timeout   = 10
           stop_command  = echo "close" > /tmp/router_trigger
   ```
3. Запустите службу: sudo systemctl enable knockd && sudo systemctl start knockd.

### Настройка на стороне OpenWRT:

1. Создайте скрипт проверки /root/check_knock.sh:

   ```bash
   #!/bin/sh
   STATUS=$(ssh -i /root/.ssh/id_dropbear user@IP_СЕРВЕРА "cat /tmp/router_trigger 2>/dev/null")
   
   if [ "$STATUS" = "open" ]; then
       if ! pgrep autossh > /dev/null; then
           autossh -M 0 -f -i /root/.ssh/id_dropbear -N -R 2222:localhost:22 -p 22 user@IP_СЕРВЕРА
       fi
   elif [ "$STATUS" = "close" ]; then
       pkill autossh
       pkill -f "dropbear"
   fi
   ```
2. Сделайте его исполняемым: chmod +x /root/check_knock.sh.
3. Добавьте проверку в планировщик Cron (crontab -e), чтобы скрипт проверял сервер каждую минуту:

   ```text
   * * * * * /root/check_knock.sh
   ```

Как подключиться к роутеру: Отправьте последовательность стуков на сервер (например, с помощью утилиты knock или мобильного приложения):

```bash
knock IP_СЕРВЕРА 7000 8000 9000
```

В течение минуты роутер считает статус open с сервера и поднимет туннель на порт 2222.