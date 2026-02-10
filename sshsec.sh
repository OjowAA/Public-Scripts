#!/bin/bash

set -e

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

echo "Configuring SSH for password authentication..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# Backup sshd config
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F-%T)"

# Enforce password authentication
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD_CONFIG"

systemctl restart sshd

echo "Configuring UFW..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable

echo "Done."
echo "UFW enabled. Only SSH allowed. SSH passwords enforced."
