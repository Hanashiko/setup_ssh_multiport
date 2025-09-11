# setup_ssh_multiport

A Bash script that installs and configures OpenSSH with support for multiple SSH ports.
It compiles OpenSSh from source, modifies the `MAX_LISTEN_SOCKS` limit, creates a new systemd service (`sshnew`), and automatically opens a user-defined number of SSH ports.

---

## Features
 - Installs OpenSSH 8.6p1 from source.
 - Modifes `MAX_LISTEN_SOCKS` to support multiple listening ports.
 - Creates a dedicated systemd service (`sshnew`) separate from the default `ssh`.
 - Automatically generates a configuration with random SSH ports.
 - Provides helper script `openports.sh` for regenerating port configuration.
 - Validates SSH configuration before starting the service.
 - Supports root login and password authentication by default (customizable).

---

## Requirements
 - Debian/Ubuntu-based system (APT package manager).
 - Root privileges (`sudo`).
 - Internet connection (to download OpenSSH sources).

--- 

## Installation

Clone the repository and run the script:
```bash
git clone https://github.com/Hanashiko/setup-ssh-multiport.git
cd setup-ssh-multiport
chmod +x setup_ssh_multiport.sh 
sudo ./setup_ssh_multiport.sh 
```

---

## Configuration Steps

During installation, the script will prompt you for:
 1. Number of SSH ports to open (default: 30).
 2. Port range (`min` and `max`, defaults: `2000-65000`).
 3. Confirmation before proceeding with compilation and setup.

---

## Service Information

After installation, a new SSH service will be available:

 - Service name: `sshnew`
 - Main config file: `/opt/openssh-9.6p1/etc/sshd_config`
 - Ports configuration: `/opt/openssh-9.6p1/etc/sshd_config.d/70-ports.conf`
 - Port regeneration script: `/opt/openssh-9.6p1/openports.sh`

---

## Useful Commands:

### View opened ports:
```bash
cat /opt/openssh-9.6p1/etc/sshd_config.d/70-ports.conf
```

### Regenerate ports:
```bash
bash /opt/openssh-9.6p1/openports.sh
```

### Check service status:
```bash
systemctl status sshnew 
```

### Restart service:
```bash
systemctl restart sshnew
```

### View logs:
```bash
journalctl -u sshnew -f
```

---

## Example Output

After installation, you'll see a summary like:
```bash
┌─────────────────────────────────────┐
│            OPEN PORTS               │
├─────────────────────────────────────┤
│ 1.  SSH Port: 22                    │
│ 2.  SSH Port: 23456                 │
│ 3.  SSH Port: 34567                 │
│ ...                                 │
├─────────────────────────────────────┤
│ Total ports: 30                     │
└─────────────────────────────────────┘
```

---

## Security Notes

 - By default, the script enabes root login and password authentication. You should adjuct `/opt/openssh-9.6p1/etc/sshd_config` for production security.
 - Make sure your fiewall (UFW/iptables/Firewalld/SELinux) is configred to allow the newly opened ports.
 - Keep OpenSSH updated to avoid security vulnerablities.

---

## Uninstall / Cleanup

To remove the custom OpenSSH installation:

```bash
systemctl stop sshnew
systemctl disable sshnew
rm -rf /opt/openssh-9.6p1
rm -f /lib/systemd/system/sshnew.service
systemctl daemon-reload
```

---

## License

This project is released under the MIT License.
