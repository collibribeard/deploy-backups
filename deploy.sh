#!/bin/bash
# deploy.sh - Déploiement de la solution de sauvegarde BorgBackup + Restic
# Usage : sudo ./deploy.sh
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Lancer ce script en root (sudo)."; exit 1; }

SRC=/srv/data
BASE=/srv/backups
BORG_REPO=$BASE/borg
RESTIC_REPO=$BASE/restic
PASSFILE=/root/.backup-pass
LOG=/var/log/backup.log

echo "[1/6] Installation des paquets"
apt-get update -qq
apt-get install -y -qq borgbackup restic

echo "[2/6] Dossiers et passphrase"
mkdir -p "$SRC" "$BORG_REPO" "$RESTIC_REPO"
[ -f "$PASSFILE" ] || openssl rand -base64 24 > "$PASSFILE"
chmod 600 "$PASSFILE"

echo "[3/6] Jeu de données de test"
if [ -z "$(ls -A "$SRC")" ]; then
  for i in 1 2 3; do head -c 10M /dev/urandom > "$SRC/file$i.bin"; done
  echo "version 1" > "$SRC/note.txt"
fi

echo "[4/6] Initialisation des dépôts chiffrés"
export BORG_PASSCOMMAND="cat $PASSFILE"
export RESTIC_PASSWORD_FILE="$PASSFILE"
[ -f "$BORG_REPO/config" ] || borg init --encryption=repokey "$BORG_REPO"
[ -f "$RESTIC_REPO/config" ] || restic init --repo "$RESTIC_REPO"
[ -f /root/borg-key.backup ] || borg key export "$BORG_REPO" /root/borg-key.backup

echo "[5/6] Script de sauvegarde avec rétention"
cat > /usr/local/sbin/backup.sh <<EOF
#!/bin/bash
set -euo pipefail
export BORG_PASSCOMMAND="cat $PASSFILE"
export RESTIC_PASSWORD_FILE="$PASSFILE"
DATE=\$(date +%F_%H-%M)
{
echo "=== \$(date) : début ==="
borg create --stats "$BORG_REPO::auto-\$DATE" "$SRC"
borg prune --list --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --glob-archives 'auto-*' "$BORG_REPO"
restic -r "$RESTIC_REPO" backup "$SRC" --tag auto
restic -r "$RESTIC_REPO" forget --tag auto --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
echo "=== \$(date) : fin ==="
} >> $LOG 2>&1
EOF
chmod 700 /usr/local/sbin/backup.sh

echo "[6/6] Planification (timer systemd)"
cat > /etc/systemd/system/backup.service <<'EOF'
[Unit]
Description=Sauvegarde Borg + Restic

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup.sh
EOF
cat > /etc/systemd/system/backup.timer <<'EOF'
[Unit]
Description=Sauvegarde quotidienne

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now backup.timer

echo "Première sauvegarde de vérification..."
systemctl start backup.service
echo "--- Borg ---";   borg list "$BORG_REPO"
echo "--- Restic ---"; restic -r "$RESTIC_REPO" snapshots
systemctl list-timers backup.timer --no-pager
echo
echo "IMPORTANT : copier $PASSFILE et /root/borg-key.backup hors de cette machine."
