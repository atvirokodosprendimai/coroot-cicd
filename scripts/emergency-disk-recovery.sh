#!/usr/bin/env bash
# emergency-disk-recovery.sh — Free disk space and restart the Coroot stack
set +e

echo "=== BEFORE ==="
df -h /

echo ""
echo "--- Removing ALL backups ---"
rm -rf /opt/coroot/backups/*
echo "Done"

echo ""
echo "--- Removing staging ---"
rm -rf /opt/coroot-staging 2>/dev/null
echo "Done"

echo ""
echo "--- Temp files ---"
find /tmp -name "*.tar.gz" -delete 2>/dev/null
find /opt -name "*.tar.gz.tmp" -delete 2>/dev/null

echo ""
echo "--- Orphan Docker volumes ---"
for vol in coroot_coroot-data coroot_caddy-data coroot_caddy-config; do
  docker volume rm "$vol" 2>/dev/null && echo "Removed $vol"
done

echo ""
echo "--- Docker prune ---"
docker system prune -f

echo ""
echo "--- System cleanup ---"
apt-get clean 2>/dev/null
journalctl --vacuum-size=50M 2>/dev/null
find /var/log -name "*.gz" -delete 2>/dev/null
find /var/log -name "*.old" -delete 2>/dev/null
find /var/log -name "*.1" -delete 2>/dev/null

echo ""
echo "=== AFTER CLEANUP ==="
df -h /

echo ""
echo "=== RESTARTING STACK ==="
cd /opt/coroot
docker compose up -d

echo ""
echo "=== WAITING FOR HEALTH (180s max) ==="
for i in $(seq 1 36); do
  sleep 5
  cs=$(docker inspect --format='{{.State.Health.Status}}' coroot-coroot-1 2>/dev/null || echo "?")
  ch=$(docker inspect --format='{{.State.Health.Status}}' coroot-clickhouse-1 2>/dev/null || echo "?")
  pr=$(docker inspect --format='{{.State.Health.Status}}' coroot-prometheus-1 2>/dev/null || echo "?")
  echo "[$i/36] coroot=$cs clickhouse=$ch prometheus=$pr"
  [ "$cs" = "healthy" ] && echo "*** RECOVERED ***" && break
done

echo ""
echo "=== STATUS ==="
docker ps -a --format "table {{.Names}}	{{.Status}}"
df -h /
curl -sf -o /dev/null -w "External: HTTP %{http_code}
" https://table.beerpub.dev/ || echo "External: still failing"
