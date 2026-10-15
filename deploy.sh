#!/bin/bash
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Erreur : exécutez ce script en root."; exit 1; }

SRC=/srv/data
BASE=/srv/backups
BORG_REPO=$BASE/borg
RESTIC_REPO=$BASE/restic
PASSFILE=/root/.backup-pass
LOG=/var/log/backup.log

apt-get update -qq
apt-get install -y -qq borgbackup restic

mkdir -p "$SRC" "$BORG_REPO" "$RESTIC_REPO"
[ -f "$PASSFILE" ] || openssl rand -base64 24 > "$PASSFILE"
chmod 600 "$PASSFILE"

if [ -z "$(ls -A "$SRC")" ]; then
  for i in 1 2 3; do head -c 10M /dev/urandom > "$SRC/file$i.bin"; done
  echo "version 1" > "$SRC/note.txt"
fi

export BORG_PASSCOMMAND="cat $PASSFILE"
export RESTIC_PASSWORD_FILE="$PASSFILE"

[ -f "$BORG_REPO/config" ] || borg init --encryption=repokey "$BORG_REPO"
[ -f "$RESTIC_REPO/config" ] || restic init --repo "$RESTIC_REPO"
[ -f /root/borg-key.backup ] || borg key export "$BORG_REPO" /root/borg-key.backup

cat > /usr/local/sbin/backup.sh <<EOF
#!/bin/bash
set -euo pipefail
export BORG_PASSCOMMAND="cat $PASSFILE"
export RESTIC_PASSWORD_FILE="$PASSFILE"
DATE=\$(date +%F_%H-%M)
{
echo "=== \$(date) ==="
borg create --stats "$BORG_REPO::auto-\$DATE" "$SRC"
borg prune --list --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --glob-archives 'auto-*' "$BORG_REPO"
restic -r "$RESTIC_REPO" backup "$SRC" --tag auto
restic -r "$RESTIC_REPO" forget --tag auto --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
} >> $LOG 2>&1
EOF
chmod 700 /usr/local/sbin/backup.sh

cat > /etc/systemd/system/backup.service <<'EOF'
[Unit]
Description=Backup Borg + Restic

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup.sh
EOF

cat > /etc/systemd/system/backup.timer <<'EOF'
[Unit]
Description=Timer sauvegarde quotidienne

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now backup.timer

systemctl start backup.service
borg list "$BORG_REPO"
restic -r "$RESTIC_REPO" snapshots
systemctl list-timers backup.timer --no-pager

echo
echo "Attention : pensez à copier $PASSFILE et /root/borg-key.backup sur une machine externe."
