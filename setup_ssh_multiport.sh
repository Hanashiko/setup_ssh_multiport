#!/bin/bash

# SSH Multi-Port Setup Script
# Автоматично встановлює OpenSSH з можливістю відкриття багатьох портів

set -e  

print_status() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

print_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

if [ "$EUID" -ne 0 ]; then
    print_error "Цей скрипт потрібно запускати з правами root (sudo)"
    exit 1
fi

echo "=== SSH Multi-Port Setup ==="
echo ""

read -p "Скільки SSH портів потрібно відкрити? (за замовчуванням: 30): " PORTS_COUNT
PORTS_COUNT=${PORTS_COUNT:-30}

if ! [[ "$PORTS_COUNT" =~ ^[0-9]+$ ]] || [ "$PORTS_COUNT" -lt 1 ]; then
    print_error "Будь ласка, введіть правильне число портів (більше 0)"
    exit 1
fi

MAX_LISTEN_SOCKS=$((PORTS_COUNT * 2))

echo ""
echo "Налаштування діапазону портів:"
read -p "Мінімальний порт (за замовчуванням: 2000): " MIN_PORT
MIN_PORT=${MIN_PORT:-2000}

read -p "Максимальний порт (за замовчуванням: 65000): " MAX_PORT
MAX_PORT=${MAX_PORT:-65000}

if ! [[ "$MIN_PORT" =~ ^[0-9]+$ ]] || ! [[ "$MAX_PORT" =~ ^[0-9]+$ ]]; then
    print_error "Порти повинні бути числами"
    exit 1
fi

if [ "$MIN_PORT" -ge "$MAX_PORT" ]; then
    print_error "Мінімальний порт повинен бути менший за максимальний"
    exit 1
fi

if [ "$MIN_PORT" -lt 1024 ]; then
    print_warning "Використання портів менше 1024 може потребувати додаткових дозволів"
fi

echo ""
print_status "Налаштування:"
print_status "  Кількість портів: $PORTS_COUNT"
print_status "  MAX_LISTEN_SOCKS: $MAX_LISTEN_SOCKS"
print_status "  Діапазон портів: $MIN_PORT-$MAX_PORT"
echo ""

read -p "Продовжити встановлення? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_status "Встановлення скасовано"
    exit 0
fi

echo ""
print_status "Початок встановлення..."

print_status "Встановлення залежностей..."
apt update
apt install -y libssl-dev gcc g++ gdb cpp make cmake libtool libc6 autoconf automake pkg-config build-essential gettext
apt install -y libzstd1 zlib1g libssh-4 libssh-dev libssl3 libc6-dev libc6 libcrypt-dev

cd /usr/local/src

VER="9.6p1"
print_status "Завантаження OpenSSH $VER..."

rm -f openssh-${VER}.tar.gz openssh-${VER}.tar.gz.asc RELEASE_KEY.asc
rm -rf openssh-${VER}

wget https://mirror.businessconnect.nl/pub/OpenBSD/OpenSSH/portable/openssh-${VER}.tar.gz
wget https://mirror.businessconnect.nl/pub/OpenBSD/OpenSSH/RELEASE_KEY.asc
wget https://mirror.businessconnect.nl/pub/OpenBSD/OpenSSH/portable/openssh-${VER}.tar.gz.asc

print_status "Перевірка підпису..."
gpg --import RELEASE_KEY.asc 2>/dev/null || print_warning "Не вдалося імпортувати GPG ключ"
gpg --verbose --verify openssh-${VER}.tar.gz.asc 2>/dev/null || print_warning "Не вдалося перевірити підпис"

print_status "Розпакування архіву..."
tar -xf openssh-${VER}.tar.gz
cd openssh-${VER}

print_status "Модифікація MAX_LISTEN_SOCKS до $MAX_LISTEN_SOCKS..."

if grep -q "MAX_LISTEN_SOCKS" sshd.c; then
    print_status "Знайдено MAX_LISTEN_SOCKS, коментування старого значення та додавання нового..."

    sed -i '/^#define[[:space:]]*MAX_LISTEN_SOCKS/c\
// #define MAX_LISTEN_SOCKS        16  /* original value */\
#define MAX_LISTEN_SOCKS        '"$MAX_LISTEN_SOCKS"' /* modified for multiple ports */' sshd.c

    print_status "Зміни в sshd.c:"
    grep -A2 -B2 "MAX_LISTEN_SOCKS" sshd.c
else
    print_error "Не знайдено #define MAX_LISTEN_SOCKS в sshd.c"
    print_status "Додавання нового визначення в початок файлу..."
    sed -i "1i #define MAX_LISTEN_SOCKS        $MAX_LISTEN_SOCKS" sshd.c
fi


print_status "Конфігурація та компіляція..."
./configure --prefix=/opt/openssh-${VER}
make
make install

print_status "Створення конфігураційних файлів..."
mkdir -p /opt/openssh-${VER}/etc/sshd_config.d
touch /opt/openssh-${VER}/etc/revoked_keys
chmod 600 /opt/openssh-${VER}/etc/revoked_keys


cp /opt/openssh-${VER}/etc/sshd_config /opt/openssh-${VER}/etc/sshd_config_backup

print_status "Налаштування sshd_config..."
cat > /opt/openssh-${VER}/etc/sshd_config << 'EOF'
Include /opt/openssh-9.6p1/etc/sshd_config.d/*.conf
PermitRootLogin yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication no
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
RevokedKeys /opt/openssh-9.6p1/etc/revoked_keys
Subsystem sftp /opt/openssh-9.6p1/libexec/sftp-server
EOF

print_status "Створення systemd сервісу..."
cat > /lib/systemd/system/sshnew.service << 'EOF'
[Unit]
Description=OpenBSD Secure Shell server
After=network.target auditd.service
ConditionPathExists=!/opt/openssh-9.6p1/etc/sshd_not_to_be_run

[Service]
EnvironmentFile=-/etc/default/ssh
ExecStartPre=/opt/openssh-9.6p1/sbin/sshd -t
ExecStart=/opt/openssh-9.6p1/sbin/sshd -D $SSHD_OPTS
ExecReload=/opt/openssh-9.6p1/sbin/sshd -t
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=exec
RuntimeDirectory=sshnew
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
Alias=sshnew.service
EOF

print_status "Створення скрипту для відкриття портів..."
cat > /opt/openssh-${VER}/openports.sh << EOF
#!/bin/bash
# SSH Ports Opening Script
# Автоматично генерує конфігурацію портів

PORTS_COUNT="$PORTS_COUNT"
MIN_PORT="$MIN_PORT"
MAX_PORT="$MAX_PORT"

echo "Відкриття \$PORTS_COUNT SSH портів в діапазоні \$MIN_PORT-\$MAX_PORT..."

# Створення конфігурації портів
echo "Port 22" > /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf

# Генерація додаткових портів
for ((i=1; i<PORTS_COUNT; i++)); do
    # Генерація унікального порту
    while true; do
        PORT=\$(shuf -i \$MIN_PORT-\$MAX_PORT -n 1)
        # Перевірка чи порт не використовується
        if ! grep -q "Port \$PORT" /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf; then
            echo "Port \$PORT" >> /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf
            break
        fi
    done
done

echo "Створено конфігурацію з \$(wc -l < /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf) портами"

# Перезапуск служби
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true
systemctl restart sshnew
systemctl enable sshnew

echo "SSH сервіс перезапущено з новими портами"
EOF

chmod +x /opt/openssh-${VER}/openports.sh

print_status "Налаштування системних служб..."
systemctl daemon-reload
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true

print_status "Запуск нової SSH служби..."
systemctl restart sshnew
systemctl enable sshnew

print_status "Відкриття SSH портів..."
bash /opt/openssh-${VER}/openports.sh

print_status "Встановлення завершено!"
echo ""
print_status "Інформація:"
print_status "  - Новий SSH демон: sshnew"
print_status "  - Конфігурація: /opt/openssh-${VER}/etc/sshd_config"
print_status "  - Порти: /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf"
print_status "  - Скрипт портів: /opt/openssh-${VER}/openports.sh"
echo ""
print_status "Перегляд відкритих портів:"
echo "cat /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf"
echo ""
print_status "Для повторного відкриття портів запустіть:"
echo "bash /opt/openssh-${VER}/openports.sh"
echo ""
print_warning "Переконайтесь що файрвол налаштований для пропуску нових портів!"
