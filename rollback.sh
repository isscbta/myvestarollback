#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:---apply}"
[[ "$MODE" == "--apply" || "$MODE" == "--dry-run" ]] || { echo 'Usage: rollback.sh [--apply|--dry-run]'; exit 2; }
[[ $EUID -eq 0 ]] || { echo 'ERROR: Run as root'; exit 2; }
for cmd in python3 tar nginx systemctl grep find cmp mktemp; do command -v "$cmd" >/dev/null || { echo "ERROR: Missing $cmd"; exit 2; }; done
NGINX_DIR=/usr/local/vesta/data/templates/web/nginx
VESTA=/usr/local/vesta
[[ -d "$NGINX_DIR" && -d /etc/php ]] || { echo 'ERROR: Missing nginx templates or /etc/php'; exit 2; }
export VESTA PATH="$PATH:/usr/local/vesta/bin"
BACKUP_DIR="/root/upload-rollback-$(date +%Y%m%d-%H%M%S)-$$"
RULE='if ($http_content_type ~* "multipart/form-data") {return 403;}'
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir "$WORK/new"
mapfile -d '' FILES < <(find "$NGINX_DIR" -type f \( -name '*.tpl' -o -name '*.stpl' \) -print0; find /etc/php -type f -name php.ini -print0)
CHANGED=()
NGINX_CHANGED=0
PHP_CHANGED=0
printf 'myVesta rollback | mode: %s\n' "$MODE"
for i in "${!FILES[@]}"; do
    file=${FILES[$i]}
    if [[ "$file" == "$NGINX_DIR"/* ]]; then kind=nginx; else kind=php; fi
    dest="$WORK/new/$i"
    python3 - "$file" "$kind" "$dest" <<'PY'
import sys
from pathlib import Path
source, kind, dest = sys.argv[1:]
data = Path(source).read_bytes()
lines = data.splitlines(keepends=True)
if kind == 'nginx':
    rule = b'if ($http_content_type ~* "multipart/form-data") {return 403;}'
    lines = [line for line in lines if line.strip() != rule]
else:
    settings = {b'session.upload_progress.enabled = 0', b'session.use_strict_mode = 1'}
    end = len(lines)
    while end and not lines[end - 1].strip(): end -= 1
    start = end
    while start and lines[start - 1].strip() in settings: start -= 1
    if start < end:
        if start and not lines[start - 1].strip(): start -= 1
        del lines[start:end]
Path(dest).write_bytes(b''.join(lines))
PY
    if ! cmp -s "$file" "$dest"; then
        CHANGED+=("$i")
        if [[ "$kind" == nginx ]]; then ((NGINX_CHANGED+=1)); else ((PHP_CHANGED+=1)); fi
        printf 'CHANGE: %s\n' "$file"
    fi
done
printf '\nNginx templates: %d | PHP ini: %d | Total: %d\n' "$NGINX_CHANGED" "$PHP_CHANGED" "${#CHANGED[@]}"
if [[ "$MODE" == --dry-run ]]; then echo 'DRY RUN: no files or services changed.'; exit 0; fi

# Back up the original PHP tree, templates and generated configuration before modification.
if ((${#CHANGED[@]})); then
    mkdir -p "$BACKUP_DIR"
    BACKUP_PATHS=("$NGINX_DIR" /etc/php /etc/nginx)
    shopt -s nullglob
    for path in /home/*/conf/web; do BACKUP_PATHS+=("$path"); done
    shopt -u nullglob
    tar -czf "$BACKUP_DIR/configurations.tar.gz" "${BACKUP_PATHS[@]}"
    tar -tzf "$BACKUP_DIR/configurations.tar.gz" >/dev/null
    echo "Backup: $BACKUP_DIR/configurations.tar.gz"
    for i in "${CHANGED[@]}"; do cat "$WORK/new/$i" > "${FILES[$i]}"; done
fi

errors=0
if ((NGINX_CHANGED)); then
    if [[ ! -x "$VESTA/bin/v-rebuild-web-domains" ]]; then
        echo 'FAIL: myVesta rebuild utility missing'; exit 1
    fi
    for userdir in "$VESTA"/data/users/*; do
        [[ -f "$userdir/user.conf" ]] || continue
        user=${userdir##*/}
        echo "Rebuilding: $user"
        if ! "$VESTA/bin/v-rebuild-web-domains" "$user" no; then
            echo "FAIL: rebuild for $user"; ((errors+=1))
        fi
    done
    if ((errors)); then echo 'FAIL: domain rebuild failed; no nginx restart'; exit 1; fi
    if ! systemctl is-active --quiet nginx; then
        echo 'SKIP: nginx nije aktivan (Apache-only server), bez restarta'
    elif nginx -t; then
        if systemctl restart nginx; then echo 'PASS: nginx restarted'; else echo 'FAIL: nginx restart'; ((errors+=1)); fi
    else
        echo 'FAIL: nginx syntax; no nginx restart'; ((errors+=1))
    fi
fi

if ((PHP_CHANGED)); then
    mapfile -t FPM_SERVICES < <(systemctl list-units --type=service --state=running --no-legend --plain | awk '$1 ~ /^php[0-9.]+-fpm\.service$/ {print $1}')
    for svc in "${FPM_SERVICES[@]}"; do
        if systemctl restart "$svc"; then echo "PASS: restarted $svc"; else echo "FAIL: restarting $svc"; ((errors+=1)); fi
    done
    if systemctl is-active --quiet apache2; then
        if command -v apache2ctl >/dev/null && apache2ctl configtest; then
            if systemctl restart apache2; then echo 'PASS: apache2 restarted'; else echo 'FAIL: apache2 restart'; ((errors+=1)); fi
        else
            echo 'FAIL: apache2ctl configtest (Apache was not restarted)'; ((errors+=1))
        fi
    fi
fi

echo '=== Automatic verification ==='
SCAN_PATHS=("$NGINX_DIR" /etc/nginx)
shopt -s nullglob
for path in /home/*/conf/web; do SCAN_PATHS+=("$path"); done
shopt -u nullglob
if grep -RFnl -- "$RULE" "${SCAN_PATHS[@]}"; then
    echo 'FAIL: blocking rule remains in files'; ((errors+=1))
else
    echo 'PASS: blocking rule absent in scanned files'
fi
if nginx -T >"$WORK/nginx-dump" 2>"$WORK/nginx-errors"; then
    if grep -Fq -- "$RULE" "$WORK/nginx-dump"; then
        echo 'FAIL: rule exists in active nginx config'; ((errors+=1))
    else
        echo 'PASS: active nginx configuration clean'
    fi
else
    echo 'FAIL: nginx -T failed'; cat "$WORK/nginx-errors"; ((errors+=1))
fi
if ! systemctl is-enabled --quiet nginx 2>/dev/null && ! systemctl is-active --quiet nginx; then echo 'SKIP: nginx nije u upotrebi'; elif nginx -t && systemctl is-active --quiet nginx; then echo 'PASS: nginx running'; else echo 'FAIL: nginx'; ((errors+=1)); fi
for svc in "${FPM_SERVICES[@]:-}"; do
    [[ -n "$svc" ]] || continue
    if systemctl is-active --quiet "$svc"; then echo "PASS: $svc running"; else echo "FAIL: $svc not running"; ((errors+=1)); fi
done
if systemctl is-active --quiet apache2; then
    if apache2ctl configtest; then echo 'PASS: apache2 syntax and service'; else echo 'FAIL: apache2 syntax'; ((errors+=1)); fi
fi
python3 - <<'PY'
from pathlib import Path
import re
print('PHP directive report (INFO only, existing directives may predate rollback):')
for p in sorted(Path('/etc/php').rglob('php.ini')):
    vals=[]
    for line in p.read_text(errors='replace').splitlines():
        match=re.match(r'^\s*(session\.(?:upload_progress\.enabled|use_strict_mode))\s*=\s*([^;#]*)',line)
        if match: vals.append(f'{match.group(1)}={match.group(2).strip()}')
    if vals: print('INFO:',p,', '.join(vals))
PY
printf '\n=== Final report ===\nNginx templates changed: %d\nPHP configurations changed: %d\nErrors: %d\n' "$NGINX_CHANGED" "$PHP_CHANGED" "$errors"
if ((${#CHANGED[@]})); then echo "Backup: $BACKUP_DIR"; fi
if ((errors)); then echo 'FAIL: ROLLBACK NEEDS ATTENTION'; exit 1; fi
echo 'SUCCESS: ROLLBACK AND CHECKS COMPLETED'
