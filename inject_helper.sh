#!/bin/bash
# =============================================================================
# CronFetcher Inject Helper
# Runs on remote hosts to inject logging into cron jobs.
#
# Usage:
#   bash inject_helper.sh inject     # Add logging to all cron jobs
#   bash inject_helper.sh rollback   # Restore original crontabs from backup
# =============================================================================

LOGFILE="/var/log/cronfetcher.log"
BACKUP_DIR="/var/lib/cronfetcher_backup"
MODE="${1:-inject}"

# =============================================================================
# Rollback mode: restore crontabs from backup
# =============================================================================
if [ "$MODE" = "rollback" ]; then
    echo "[rollback] Starting..."
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "[rollback] ERROR: Backup directory not found: $BACKUP_DIR"
        exit 1
    fi
    for backup_file in "$BACKUP_DIR"/*.crontab; do
        [ -f "$backup_file" ] || continue
        user=$(basename "$backup_file" .crontab)
        sudo crontab -u "$user" "$backup_file"
        echo "[rollback] OK: $user"
    done
    echo "[rollback] Complete."
    exit 0
fi

# =============================================================================
# Inject mode: add logging to all cron jobs
# =============================================================================
sudo mkdir -p "$BACKUP_DIR"
sudo chmod 700 "$BACKUP_DIR"
sudo touch "$LOGFILE" 2>/dev/null
sudo chmod 666 "$LOGFILE" 2>/dev/null

for user in root $(grep -v '/sbin/nologin' /etc/passwd | grep -v '/bin/false' | grep -v '/sbin/halt' | grep -v '/sbin/shutdown' | grep -v '/bin/sync' | cut -d: -f1 | grep -v '^root$'); do
    CRONTAB=$(sudo crontab -l -u "$user" 2>/dev/null)
    [ -z "$CRONTAB" ] && continue

    # Backup current crontab
    echo "$CRONTAB" | sudo tee "$BACKUP_DIR/${user}.crontab" > /dev/null
    echo "[inject] Backup: $BACKUP_DIR/${user}.crontab"

    NEW_CRONTAB=""
    CHANGED=0
    while IFS= read -r line; do
        # Skip empty lines and comments
        if echo "$line" | grep -qE '^\s*$|^\s*#'; then
            NEW_CRONTAB="${NEW_CRONTAB}${line}
"
            continue
        fi
        # Skip environment variable lines
        if echo "$line" | grep -qE '^(SHELL|PATH|MAILTO|HOME)='; then
            NEW_CRONTAB="${NEW_CRONTAB}${line}
"
            continue
        fi
        # Skip already injected lines
        if echo "$line" | grep -q 'cronfetcher'; then
            echo "[inject] SKIP (already injected): $line"
            NEW_CRONTAB="${NEW_CRONTAB}${line}
"
            continue
        fi

        # Extract the full command
        if echo "$line" | grep -qE '^@'; then
            FULL_CMD=$(echo "$line" | awk '{for(i=2;i<=NF;i++) printf "%s ",$i}' | sed 's/ $//')
        else
            FULL_CMD=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ",$i}' | sed 's/ $//')
        fi

        # Inject: always log with exit code (OK or FAIL)
        INJECT="${line} ; rc=\$?; if [ \$rc -eq 0 ]; then st=OK; else st=FAIL; fi; echo \"\$(date '+\%Y-\%m-\%d \%H:\%M:\%S')|${user}|${FULL_CMD}|\$st\" >> ${LOGFILE}"

        echo "[inject] OK: $user"
        NEW_CRONTAB="${NEW_CRONTAB}${INJECT}
"
        CHANGED=1
    done <<< "$CRONTAB"

    if [ "$CHANGED" -eq 1 ]; then
        echo "$NEW_CRONTAB" | sudo crontab -u "$user" -
        echo "[inject] UPDATED: $user"
    fi
done

echo "[inject] Complete."
