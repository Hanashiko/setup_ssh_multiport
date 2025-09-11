#!/bin/bash

# SSH Multi-Port Setup Script
# Automatically installs OpenSSH with support for multiple ports

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
    print_error "This script must be run as root (sudo)"
    exit 1
fi

echo "=== SSH Multi-Port Setup ==="
echo ""

read -p "Hoe many SSH ports do you want to open? (default: 30): " PORTS_COUNT
PORTS_COUNT=${PORTS_COUNT:-30}

if ! [[ "$PORTS_COUNT" =~ ^[0-9]+$ ]] || [ "$PORTS_COUNT" -lt 1 ]; then
    print_error "Please enter a valid number of ports (greater than 0)"
    exit 1
fi

MAX_LISTEN_SOCKS=$((PORTS_COUNT * 2))

echo ""
echo "Port range configuration:"
read -p "Minimum port (default: 2000): " MIN_PORT
MIN_PORT=${MIN_PORT:-2000}

read -p "Maximum port (default: 65000): " MAX_PORT
MAX_PORT=${MAX_PORT:-65000}

if ! [[ "$MIN_PORT" =~ ^[0-9]+$ ]] || ! [[ "$MAX_PORT" =~ ^[0-9]+$ ]]; then
    print_error "Ports must be numbers"
    exit 1
fi

if [ "$MIN_PORT" -ge "$MAX_PORT" ]; then
    print_error "Minimum port must be less than maximum port"
    exit 1
fi

if [ "$MIN_PORT" -lt 1024 ]; then
    print_warning "Using ports below 1024 may require additional privileges"
fi

echo ""
print_status "Confguration:"
print_status "  Number of ports: $PORTS_COUNT"
print_status "  MAX_LISTEN_SOCKS: $MAX_LISTEN_SOCKS"
print_status "  Port range: $MIN_PORT-$MAX_PORT"
echo ""

read -p "Proceed with installation? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_status "Installation cancelled"
    exit 0
fi

echo ""
print_status "Starting installation..."

print_status "Installing dependencies..."
apt update
apt install -y libssl-dev gcc g++ gdb cpp make cmake libtool libc6 autoconf automake pkg-config build-essential gettext
apt install -y libzstd1 zlib1g libssh-4 libssh-dev libssl3 libc6-dev libc6 libcrypt-dev

cd /usr/local/src

VER="9.6p1"
print_status "Downloading OpenSSH $VER..."

rm -f openssh-${VER}.tar.gz openssh-${VER}.tar.gz.asc RELEASE_KEY.asc
rm -rf openssh-${VER}

wget https://mirror.businessconnect.nl/pub/OpenBSD/OpenSSH/portable/openssh-${VER}.tar.gz
wget https://mirror.businessconnect.nl/pub/OpenBSD/OpenSSH/RELEASE_KEY.asc
wget https://mirror.businessconnect.nl/pub/OpenBSD/OpenSSH/portable/openssh-${VER}.tar.gz.asc

print_status "Verifying signature..."
gpg --import RELEASE_KEY.asc 2>/dev/null || print_warning "Failed to import GPG key"
gpg --verbose --verify openssh-${VER}.tar.gz.asc 2>/dev/null || print_warning "Failed to verify signature"

print_status "Extracting archive..."
tar -xf openssh-${VER}.tar.gz
cd openssh-${VER}

print_status "Modifying MAX_LISTEN_SOCKS to $MAX_LISTEN_SOCKS..."

if grep -q "MAX_LISTEN_SOCKS" sshd.c; then
    print_status "Found MAX_LISTEN_SOCKS, commenting old value and adding new one..."

    sed -i '/^#define[[:space:]]*MAX_LISTEN_SOCKS/c\
// #define MAX_LISTEN_SOCKS        16  /* original value */\
#define MAX_LISTEN_SOCKS        '"$MAX_LISTEN_SOCKS"' /* modified for multiple ports */' sshd.c

    print_status "Changes in sshd.c:"
    grep -A2 -B2 "MAX_LISTEN_SOCKS" sshd.c
else
    print_error "Did not find #define MAX_LISTEN_SOCKS in sshd.c"
    print_status "Adding new definition at the top of the file..."
    sed -i "1i #define MAX_LISTEN_SOCKS        $MAX_LISTEN_SOCKS" sshd.c
fi


print_status "Configuring and compiling..."
./configure --prefix=/opt/openssh-${VER}
make
make install

print_status "Creating configuration files..."
mkdir -p /opt/openssh-${VER}/etc/sshd_config.d
touch /opt/openssh-${VER}/etc/revoked_keys
chmod 600 /opt/openssh-${VER}/etc/revoked_keys

cp /opt/openssh-${VER}/etc/sshd_config /opt/openssh-${VER}/etc/sshd_config_backup

print_status "Configuring sshd_config..."
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

print_status "Creating systemd service..."
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

print_status "Creating script for opening ports..."
cat > /opt/openssh-${VER}/openports.sh << EOF
#!/bin/bash
# SSH Ports Opening Script
# Automatically generates port configuration

PORTS_COUNT="$PORTS_COUNT"
MIN_PORT="$MIN_PORT"
MAX_PORT="$MAX_PORT"

echo "Opening \$PORTS_COUNT SSH ports in range \$MIN_PORT-\$MAX_PORT..."

echo "Port 22" > /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf

for ((i=1; i<PORTS_COUNT; i++)); do
    while true; do
        PORT=\$(shuf -i \$MIN_PORT-\$MAX_PORT -n 1)
        if ! grep -q "Port \$PORT" /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf; then
            echo "Port \$PORT" >> /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf
            break
        fi
    done
done

echo "Configuration created with \$(wc -l < /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf) ports"

systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true
systemctl restart sshnew
systemctl enable sshnew

echo "SSH service restarted with new ports"
EOF

chmod +x /opt/openssh-${VER}/openports.sh

print_status "Configuring system services..."
systemctl daemon-reload
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true

print_status "Waiting for processes to finish..."
sleep 3

print_status "Checking SSH configuration..."
if /opt/openssh-${VER}/sbin/sshd -t; then
    print_status "✅ SSH configuration is valid"
else
    print_error "❌ SSH configuration is invalid! Check your settings."
    exit 1
fi

print_status "Starting new SSH service..."
systemctl start sshnew
sleep 2
systemctl enable sshnew
sleep 10
systemctl restart sshnew

if systemctl is-active --quiet sshnew; then
    print_status "✅ SSH service started successfully"
else
    print_warning "Service did not start, retrying..."
    sleep 3
    systemctl restart sshnew
    sleep 2
    if systemctl is-active --quiet sshnew; then
        print_status "✅ SSH service started after retry"
    else
        print_error "❌ Failed to start SSH service"
        print_status "Use the following command for diagnostics: journalctl -u sshnew"
        exit 1
    fi
fi

print_status "Opening SSH ports..."
bash /opt/openssh-${VER}/openports.sh

print_status "Installation completed!"
echo ""
print_status "Information:"
print_status "  - New SSH daemon: sshnew"
print_status "  - Configuration: /opt/openssh-${VER}/etc/sshd_config"
print_status "  - Ports: /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf"
print_status "  - Ports script: /opt/openssh-${VER}/openports.sh"
echo ""


print_status "Opened SSH ports:"
if [ -f "/opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf" ]; then
    echo "┌─────────────────────────────────────┐"
    echo "│            OPEN PORTS               │"
    echo "├─────────────────────────────────────┤"

    PORTS_ARRAY=($(grep "^Port " "/opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf" | awk '{print $2}'))
    PORT_COUNT=${#PORTS_ARRAY[@]}

    if [ $PORT_COUNT -gt 0 ]; then
        for i in "${!PORTS_ARRAY[@]}"; do
            PORT_NUM=$((i + 1))
            printf "│ %-3d. SSH Port: %-18s │\n" "$PORT_NUM" "${PORTS_ARRAY[$i]}"
        done

        echo "├─────────────────────────────────────┤"
        printf "│ Total ports: %-16d │\n" "$PORT_COUNT"
        echo "└─────────────────────────────────────┘"
        echo ""

        PORTS_LIST=""
        for port in "${PORTS_ARRAY[@]}"; do
            if [ -z "$PORTS_LIST" ]; then
                PORTS_LIST="$port"
            else
                PORTS_LIST="$PORTS_LIST, $port"
            fi
        done

        print_status "Ports summary: $PORTS_LIST"
    else
        echo "│       No ports found                │"
        echo "└─────────────────────────────────────┘"
        echo ""
        print_warning "No ports found in configuration"
        print_status "Configuration file content:"
        cat "/opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf"
    fi
    echo ""

    print_status "SSH service status:"
    if systemctl is-active --quiet sshnew; then
        echo "🟢 sshnew service is active and running"
    else
        echo "🔴 sshnew service  is not active"
    fi

    if systemctl is-enabled --quiet sshnew; then
        echo "🟢 sshnew service is enabled for autostart"
    else
        echo "🟡 sshnew servie is not enabled for autostart"
    fi

else
    print_error "Ports configuration file not found!"
fi

echo ""
print_status "Useful commands:"
echo "• View ports: cat /opt/openssh-${VER}/etc/sshd_config.d/70-ports.conf"
echo "• Regenerate ports: bash /opt/openssh-${VER}/openports.sh"
echo "• Servie status: systemctl status sshnew"
echo "• Restart service: systemctl restart sshnew"
echo "• Service logs: journalctl -u sshnew -f"
echo ""
print_warning "⚠️  IMPORTANT: Make sure your firewall is configured to allow new ports!"
