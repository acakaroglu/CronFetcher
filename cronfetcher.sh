#!/bin/bash
# =============================================================================
# CronFetcher - Satellite/Foreman Cron Job Monitor
# https://github.com/youruser/cronfetcher
#
# Scans all managed hosts for cron jobs, collects execution logs,
# and sends an HTML report via email.
# =============================================================================

SCRIPT_DIR="$(dirname $(readlink -f $0))"
CONF_FILE="${CRONFETCHER_CONF:-$SCRIPT_DIR/cronfetcher.conf}"

# --- Load configuration ---
if [ -f "$CONF_FILE" ]; then
    source "$CONF_FILE"
else
    echo "ERROR: Config file not found: $CONF_FILE"
    echo "Copy cronfetcher.conf.example to cronfetcher.conf and adjust values."
    exit 1
fi

# --- Defaults ---
SSH_KEY="${SSH_KEY:-/var/lib/foreman-proxy/ssh/id_rsa_foreman_proxy}"
SSH_USER="${SSH_USER:-satellite-automation}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o LogLevel=ERROR"

MAIL_TO="${MAIL_TO:-admin@example.com}"
MAIL_FROM="${MAIL_FROM:-cronfetcher@example.com}"
SMTP_HOST="${SMTP_HOST:-localhost}"
SMTP_PORT="${SMTP_PORT:-25}"

HOST_SOURCE="${HOST_SOURCE:-hammer}"
HAMMER_CACHE_TTL="${HAMMER_CACHE_TTL:-86400}"
HAMMER_CACHE_FILE="${HAMMER_CACHE_FILE:-/tmp/cronfetcher_hosts.cache}"

REMOTE_LOGFILE="${REMOTE_LOGFILE:-/var/log/cronfetcher.log}"

TMPDIR="/tmp/cronfetcher_$$"

# =============================================================================
# Helper: Get host list
# =============================================================================
get_host_list() {
    if [ "$HOST_SOURCE" = "file" ]; then
        cat "$HOST_FILE" 2>/dev/null | grep -v "^#" | grep "|"
        return
    fi

    # Hammer with optional cache
    if [ "$HAMMER_CACHE_TTL" -gt 0 ] 2>/dev/null && [ -f "$HAMMER_CACHE_FILE" ]; then
        CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$HAMMER_CACHE_FILE") ))
        if [ "$CACHE_AGE" -lt "$HAMMER_CACHE_TTL" ]; then
            cat "$HAMMER_CACHE_FILE"
            return
        fi
    fi

    HOST_LIST=$(sudo hammer host list --per-page 999 --fields name,ip 2>/dev/null \
        | grep -v "^-" | grep -v "NAME" | grep -v "^$" | grep -v "Page" \
        | awk '{print $1"|"$3}' | sed 's/[[:space:]]*$//' | grep -v "^|" | grep "|[0-9]")

    if [ "$HAMMER_CACHE_TTL" -gt 0 ] 2>/dev/null && [ -n "$HOST_LIST" ]; then
        echo "$HOST_LIST" > "$HAMMER_CACHE_FILE"
    fi

    echo "$HOST_LIST"
}

# =============================================================================
# --scan mode: collect crontabs from a host
# =============================================================================
if [ "$1" = "--scan" ]; then
    ENTRY="$2"; OUTDIR="$3"
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    CONNECT=$(echo "$ENTRY" | cut -d'|' -f2)
    OUTFILE="$OUTDIR/$HOST"

    CRON_DATA=$(sudo ssh $SSH_OPTS ${SSH_USER}@${CONNECT} "
        echo '###CRONSTART###'
        ROOT_CRON=\$(sudo crontab -l -u root 2>/dev/null | grep -v '^\s*#' | grep -v '^\s*\$' | grep -Ev '^(SHELL|PATH|MAILTO|HOME)=')
        if [ -n \"\$ROOT_CRON\" ]; then
            while IFS= read -r line; do echo \"CRON_JOB|root|\$line\"; done <<< \"\$ROOT_CRON\"
        fi
        for user in \$(grep -v '/sbin/nologin' /etc/passwd | grep -v '/bin/false' | grep -v '/sbin/halt' | grep -v '/sbin/shutdown' | grep -v '/bin/sync' | cut -d: -f1 | grep -v '^root\$'); do
            crons=\$(sudo crontab -l -u \"\$user\" 2>/dev/null | grep -v '^\s*#' | grep -v '^\s*\$' | grep -Ev '^(SHELL|PATH|MAILTO|HOME)=')
            if [ -n \"\$crons\" ]; then
                while IFS= read -r line; do echo \"CRON_JOB|\$user|\$line\"; done <<< \"\$crons\"
            fi
        done
        echo '###CRONEND###'
    " 2>/dev/null | sed -n '/###CRONSTART###/,/###CRONEND###/p' | grep "^CRON_JOB")

    if [ -z "$CRON_DATA" ]; then
        echo "SSH_FAILED" > "$OUTFILE"
    else
        { echo "HOST_OK"; echo "$CRON_DATA"; echo "RAN_CMDS_START"; } > "$OUTFILE"
    fi
    exit 0
fi

# =============================================================================
# --log mode: collect execution logs (frequency-aware depth)
# =============================================================================
if [ "$1" = "--log" ]; then
    ENTRY="$2"; OUTDIR="$3"
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    CONNECT=$(echo "$ENTRY" | cut -d'|' -f2)
    OUTFILE="$OUTDIR/$HOST"

    grep -q "^HOST_OK" "$OUTFILE" 2>/dev/null || exit 0

    # Check if host has weekly/monthly jobs to determine log window
    HAS_WEEKLY=$(grep "^CRON_JOB" "$OUTFILE" | awk -F'|' '{
        line=$3; for(i=4;i<=NF;i++) line=line"|"$i
        n=split(line,a," ")
        if(substr(line,1,1)!="@") {
            dow=a[5]
            if(dow!="*") { print "yes"; exit }
        }
    }')
    HAS_MONTHLY=$(grep "^CRON_JOB" "$OUTFILE" | awk -F'|' '{
        line=$3; for(i=4;i<=NF;i++) line=line"|"$i
        n=split(line,a," ")
        if(substr(line,1,1)!="@") {
            dom=a[3]
            if(dom!="*") { print "yes"; exit }
        }
    }')

    SINCE_DAILY=$(date -d 'yesterday' '+%Y-%m-%d')
    SINCE_WEEKLY=$(date -d '7 days ago' '+%Y-%m-%d')
    SINCE_MONTHLY=$(date -d '35 days ago' '+%Y-%m-%d')

    if [ "$HAS_MONTHLY" = "yes" ]; then
        SINCE="$SINCE_MONTHLY"
    elif [ "$HAS_WEEKLY" = "yes" ]; then
        SINCE="$SINCE_WEEKLY"
    else
        SINCE="$SINCE_DAILY"
    fi

    # Single SSH: prefer cronfetcher.log (injected hosts), fallback to system logs
    REMOTE_LOG=$(sudo ssh $SSH_OPTS ${SSH_USER}@${CONNECT} "if [ -s $REMOTE_LOGFILE ]; then cat $REMOTE_LOGFILE; else sudo journalctl -u crond --since $SINCE --no-pager 2>/dev/null; sudo grep CMD /var/log/cron* 2>/dev/null; fi" 2>/dev/null)

    if echo "$REMOTE_LOG" | grep -qE '\|(OK|FAIL)$'; then
        # CronFetcher log format: timestamp|user|cmd|OK/FAIL
        echo "$REMOTE_LOG" | grep -E '\|(OK|FAIL)$' \
            | awk -F'|' -v since="$SINCE" '$1>=since{cmd=$3; if($1>ts[cmd]) ts[cmd]=$1} END{for(c in ts) print "NOW "ts[c]"|"c}' >> "$OUTFILE"
    else
        # Fallback: parse system cron logs
        echo "$REMOTE_LOG" | grep CMD | sed 's/.*CMD (\(.*\))/\1/' | sed 's/ &&.*//' \
            | sort -u | while IFS= read -r c; do echo "NOW $c"; done >> "$OUTFILE"
    fi
    exit 0
fi

# =============================================================================
# --inject mode: inject logging into a single host
# =============================================================================
if [ "$1" = "--inject" ]; then
    ENTRY="$2"
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    CONNECT=$(echo "$ENTRY" | cut -d'|' -f2)
    INJECT_HELPER="$SCRIPT_DIR/inject_helper.sh"

    if [ ! -f "$INJECT_HELPER" ]; then
        echo "ERROR: inject_helper.sh not found: $INJECT_HELPER"
        exit 1
    fi

    echo "[inject] $HOST -> $CONNECT starting..."
    sudo scp $SSH_OPTS "$INJECT_HELPER" ${SSH_USER}@${CONNECT}:/tmp/cronfetcher_inject.sh 2>/dev/null
    sudo ssh $SSH_OPTS ${SSH_USER}@${CONNECT} "bash /tmp/cronfetcher_inject.sh inject; rm -f /tmp/cronfetcher_inject.sh"
    echo "[inject] $HOST done."
    exit 0
fi

# =============================================================================
# --rollback mode: remove injection from a single host
# =============================================================================
if [ "$1" = "--rollback" ]; then
    ENTRY="$2"
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    CONNECT=$(echo "$ENTRY" | cut -d'|' -f2)
    INJECT_HELPER="$SCRIPT_DIR/inject_helper.sh"

    echo "[rollback] $HOST -> $CONNECT starting..."
    sudo scp $SSH_OPTS "$INJECT_HELPER" ${SSH_USER}@${CONNECT}:/tmp/cronfetcher_inject.sh 2>/dev/null
    sudo ssh $SSH_OPTS ${SSH_USER}@${CONNECT} "bash /tmp/cronfetcher_inject.sh rollback; rm -f /tmp/cronfetcher_inject.sh"
    echo "[rollback] $HOST done."
    exit 0
fi

# =============================================================================
# --inject-all mode: inject logging into all hosts
# =============================================================================
if [ "$1" = "--inject-all" ]; then
    SCRIPT_PATH="$(readlink -f $0)"
    INJECT_HELPER="$SCRIPT_DIR/inject_helper.sh"

    if [ ! -f "$INJECT_HELPER" ]; then
        echo "ERROR: inject_helper.sh not found: $INJECT_HELPER"
        exit 1
    fi

    echo "[inject-all] Fetching host list..."
    HOST_LIST=$(get_host_list)

    TOTAL=$(echo "$HOST_LIST" | grep -c ".")
    echo "[inject-all] $TOTAL hosts found."

    SUCCESS=0; FAIL=0
    while IFS= read -r ENTRY; do
        [ -z "$ENTRY" ] && continue
        HOST=$(echo "$ENTRY" | cut -d'|' -f1)
        CONNECT=$(echo "$ENTRY" | cut -d'|' -f2)

        echo "[inject-all] $HOST ($CONNECT)..."
        sudo scp $SSH_OPTS "$INJECT_HELPER" ${SSH_USER}@${CONNECT}:/tmp/cronfetcher_inject.sh 2>/dev/null
        if sudo ssh $SSH_OPTS ${SSH_USER}@${CONNECT} "bash /tmp/cronfetcher_inject.sh inject; rm -f /tmp/cronfetcher_inject.sh" 2>/dev/null; then
            echo "[inject-all] OK: $HOST"
            SUCCESS=$((SUCCESS+1))
        else
            echo "[inject-all] FAIL: $HOST"
            FAIL=$((FAIL+1))
        fi
    done <<< "$HOST_LIST"

    echo "[inject-all] Complete: $SUCCESS succeeded, $FAIL failed / $TOTAL total"
    exit 0
fi

# =============================================================================
# --rollback-all mode: remove injection from all hosts
# =============================================================================
if [ "$1" = "--rollback-all" ]; then
    SCRIPT_PATH="$(readlink -f $0)"
    INJECT_HELPER="$SCRIPT_DIR/inject_helper.sh"

    if [ ! -f "$INJECT_HELPER" ]; then
        echo "ERROR: inject_helper.sh not found: $INJECT_HELPER"
        exit 1
    fi

    echo "[rollback-all] Fetching host list..."
    HOST_LIST=$(get_host_list)

    TOTAL=$(echo "$HOST_LIST" | grep -c ".")
    echo "[rollback-all] $TOTAL hosts found."

    SUCCESS=0; FAIL=0
    while IFS= read -r ENTRY; do
        [ -z "$ENTRY" ] && continue
        HOST=$(echo "$ENTRY" | cut -d'|' -f1)
        CONNECT=$(echo "$ENTRY" | cut -d'|' -f2)

        echo "[rollback-all] $HOST ($CONNECT)..."
        sudo scp $SSH_OPTS "$INJECT_HELPER" ${SSH_USER}@${CONNECT}:/tmp/cronfetcher_inject.sh 2>/dev/null
        if sudo ssh $SSH_OPTS ${SSH_USER}@${CONNECT} "bash /tmp/cronfetcher_inject.sh rollback; rm -f /tmp/cronfetcher_inject.sh" 2>/dev/null; then
            echo "[rollback-all] OK: $HOST"
            SUCCESS=$((SUCCESS+1))
        else
            echo "[rollback-all] FAIL: $HOST"
            FAIL=$((FAIL+1))
        fi
    done <<< "$HOST_LIST"

    echo "[rollback-all] Complete: $SUCCESS succeeded, $FAIL failed / $TOTAL total"
    exit 0
fi

# =============================================================================
# --help
# =============================================================================
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "CronFetcher - Satellite/Foreman Cron Job Monitor"
    echo ""
    echo "Usage:"
    echo "  $0                              Run full scan + report + email"
    echo "  $0 --inject  hostname|ip        Inject logging on a single host"
    echo "  $0 --rollback hostname|ip       Remove injection from a single host"
    echo "  $0 --inject-all                 Inject logging on all managed hosts"
    echo "  $0 --rollback-all               Remove injection from all managed hosts"
    echo "  $0 --help                       Show this help"
    echo ""
    echo "Configuration: $CONF_FILE"
    exit 0
fi

# =============================================================================
# Main: Full scan + report + email
# =============================================================================
mkdir -p "$TMPDIR"
DATE=$(date '+%d.%m.%Y %H:%M')
SCRIPT_PATH="$(readlink -f $0)"

echo "[$(date '+%H:%M:%S')] Fetching host list..."
HOST_LIST=$(get_host_list)

TOTAL_HOSTS=$(echo "$HOST_LIST" | grep -c ".")
echo "[$(date '+%H:%M:%S')] $TOTAL_HOSTS hosts found."

# =============================================================================
# Phase 1: Cron discovery
# =============================================================================
echo "[$(date '+%H:%M:%S')] Phase 1: Collecting cron jobs..."

while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    bash "$SCRIPT_PATH" --scan "$ENTRY" "$TMPDIR" &
done <<< "$HOST_LIST"
wait

# Retry failed hosts
RETRY_LIST=""
while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    grep -q "^SSH_FAILED" "$TMPDIR/$HOST" 2>/dev/null && RETRY_LIST="$RETRY_LIST
$ENTRY"
done <<< "$HOST_LIST"
RETRY_LIST=$(echo "$RETRY_LIST" | grep -v "^$")

if [ -n "$RETRY_LIST" ]; then
    RETRY_COUNT=$(echo "$RETRY_LIST" | grep -c ".")
    echo "[$(date '+%H:%M:%S')] Retry: $RETRY_COUNT hosts..."
    for attempt in 1 2 3; do
        STILL_FAILED=""
        while IFS= read -r ENTRY; do
            [ -z "$ENTRY" ] && continue
            HOST=$(echo "$ENTRY" | cut -d'|' -f1)
            grep -q "^SSH_FAILED" "$TMPDIR/$HOST" 2>/dev/null && STILL_FAILED="$STILL_FAILED
$ENTRY"
        done <<< "$RETRY_LIST"
        RETRY_LIST=$(echo "$STILL_FAILED" | grep -v "^$")
        [ -z "$RETRY_LIST" ] && break
        while IFS= read -r ENTRY; do
            [ -z "$ENTRY" ] && continue
            bash "$SCRIPT_PATH" --scan "$ENTRY" "$TMPDIR" &
        done <<< "$RETRY_LIST"
        wait
    done
fi

HOSTS_WITH_CRON=""
while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    grep -q "^HOST_OK" "$TMPDIR/$HOST" 2>/dev/null && HOSTS_WITH_CRON="$HOSTS_WITH_CRON
$ENTRY"
done <<< "$HOST_LIST"
HOSTS_WITH_CRON=$(echo "$HOSTS_WITH_CRON" | grep -v "^$")
CRON_HOST_COUNT=$(echo "$HOSTS_WITH_CRON" | grep -c ".")
echo "[$(date '+%H:%M:%S')] Hosts with cron: $CRON_HOST_COUNT / $TOTAL_HOSTS"

# =============================================================================
# Phase 2: Log collection
# =============================================================================
echo "[$(date '+%H:%M:%S')] Phase 2: Collecting execution logs..."

while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    bash "$SCRIPT_PATH" --log "$ENTRY" "$TMPDIR" &
done <<< "$HOSTS_WITH_CRON"
wait
echo "[$(date '+%H:%M:%S')] Phase 2 complete."

# =============================================================================
# Statistics
# =============================================================================
TOTAL_JOBS=0; FAILED_HOSTS=0; SUCCESS_HOSTS=0

while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    OUTFILE="$TMPDIR/$HOST"
    [ -f "$OUTFILE" ] || { FAILED_HOSTS=$((FAILED_HOSTS+1)); continue; }
    if grep -q "^HOST_OK" "$OUTFILE"; then
        SUCCESS_HOSTS=$((SUCCESS_HOSTS+1))
        JOB_COUNT=$(grep -c "^CRON_JOB" "$OUTFILE" || true)
        TOTAL_JOBS=$((TOTAL_JOBS+JOB_COUNT))
    fi
done <<< "$HOST_LIST"

# =============================================================================
# HTML Report
# =============================================================================
REPORT="$TMPDIR/report.html"

TOTAL_RAN=0; TOTAL_NOTRAN=0
PROB_DAILY=""; PROB_HOURLY=""; PROB_WEEKLY=""; PROB_REBOOT=""
DETAIL_HTML="$TMPDIR/detail.html"
> "$DETAIL_HTML"

while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    HOST=$(echo "$ENTRY" | cut -d'|' -f1)
    OUTFILE="$TMPDIR/$HOST"
    grep -q "^HOST_OK" "$OUTFILE" 2>/dev/null || continue

    RESULT=$(awk -v host="$HOST" '
    # --- First pass: collect NOW lines ---
    NR==FNR {
        if (/^NOW /) {
            line=$0; sub(/^NOW /,"",line)
            p=index(line,"|")
            if (p>0) {
                ts=substr(line,1,p-1)
                c=substr(line,p+1)
                ran_cmds["NOW "c]=1
                if (ts>ran_ts[c]) ran_ts[c]=ts
            } else {
                ran_cmds[$0]=1
            }
        }
        next
    }

    # --- Second pass: process CRON_JOB lines ---
    BEGIN { host_ran=0; host_total=0; table_rows=""
            prob_daily=""; prob_hourly=""; prob_weekly=""; prob_reboot="" }

    /^CRON_JOB/ {
        user=$0; sub(/^CRON_JOB\|/,"",user); sub(/\|.*/,"",user)
        line=$0; sub(/^CRON_JOB\|[^|]*\|/,"",line)
        if (line=="") next

        if (substr(line,1,1)=="@") {
            n=split(line,a," "); schedule=a[1]
            cmd=""; for(i=2;i<=n;i++) cmd=cmd (i>2?" ":"") a[i]
        } else {
            n=split(line,a," ")
            schedule=a[1]" "a[2]" "a[3]" "a[4]" "a[5]
            cmd=""; for(i=6;i<=n;i++) cmd=cmd (i>6?" ":"") a[i]
        }

        # Strip inject suffix
        idx = index(cmd, " && echo")
        if (idx > 0) cmd = substr(cmd, 1, idx-1)
        idx = index(cmd, " ; rc=")
        if (idx > 0) cmd = substr(cmd, 1, idx-1)

        # Frequency category and human-readable description
        cat="daily"
        if (schedule=="@reboot") { freq="On boot"; cat="reboot" }
        else if (schedule=="@daily") { freq="Daily 00:00"; cat="daily" }
        else if (schedule=="@hourly") { freq="Every hour"; cat="hourly" }
        else if (schedule=="@weekly") { freq="Weekly (Sun)"; cat="weekly" }
        else if (schedule=="@monthly") { freq="Monthly (1st)"; cat="monthly" }
        else if (schedule=="* * * * *") { freq="Every minute"; cat="minutely" }
        else {
            split(schedule,s," ")
            min=s[1]; hour=s[2]; dom=s[3]; mon=s[4]; dow=s[5]

            if (min ~ /^\*\//) {
                n_val=min; sub(/\*\//,"",n_val)
                freq="Every " n_val " min"; cat="minutely"
            }
            else if (hour=="*" && dom=="*" && dow=="*") {
                if (min+0==0) { freq="Every hour"; cat="hourly" }
                else { freq="Hourly at :" sprintf("%02d",min+0); cat="hourly" }
            }
            else if (hour ~ /^\*\//) {
                n_val=hour; sub(/\*\//,"",n_val)
                freq="Every " n_val "h"; cat="hourly"
            }
            else if (min=="*" && hour!="*" && dom=="*") {
                freq="Every min during hour " hour; cat="hourly"
            }
            else if (dow!="*") {
                split("Sun:Mon:Tue:Wed:Thu:Fri:Sat",dn,":")
                if (dow=="0,1,2,3,4,5,6" || dow=="1,2,3,4,5,6,0" || dow=="0-6" || dow=="1-7") {
                    time_str=(min!="*"&&hour!="*") ? hour":"sprintf("%02d",min+0) : ""
                    freq="Daily " time_str; cat="daily"
                } else if (dow=="1-5" || dow=="1,2,3,4,5") {
                    time_str=(min!="*"&&hour!="*") ? hour":"sprintf("%02d",min+0) : ""
                    freq="Weekdays " time_str; cat="weekly"
                } else {
                    dow_int=dow+0
                    if (dow_int>=0 && dow_int<=6) dow_name=dn[dow_int+1]
                    else dow_name=dow
                    time_str=(min!="*"&&hour!="*") ? hour":"sprintf("%02d",min+0) : ""
                    freq="Every " dow_name " " time_str; cat="weekly"
                }
            }
            else if (dom!="*") {
                time_str=(min!="*"&&hour!="*") ? hour":"sprintf("%02d",min+0) : ""
                freq="Monthly day " dom " " time_str; cat="monthly"
            }
            else if (hour ~ /,/) {
                freq="Daily at " hour ":00"; cat="daily"
            }
            else if (min!="*" && hour!="*") {
                freq="Daily " hour":"sprintf("%02d",min+0); cat="daily"
            }
            else { freq=schedule; cat="daily" }
        }

        # Match against collected run data
        gsub(/^[ \t]+|[ \t]+$/, "", cmd)
        split(cmd,ca," "); cmd_bare=ca[1]
        ran=0; last_ts=""
        for(rc in ran_cmds) { if(index(rc,cmd_bare)>0){ran=1;break} }
        for(rc in ran_ts) { if(index(rc,cmd_bare)>0 && ran_ts[rc]>last_ts) last_ts=ran_ts[rc] }

        if (cat=="reboot") {
            if (ran) { bg="#E8F5E9"; rs="<span style=\"color:#388E3C\">&#10003;</span> " (last_ts!="" ? last_ts : "Ran (boot)"); host_ran++ }
            else { bg="#EDE7F6"; rs="&#8505; Awaiting reboot" }
        } else if (cat=="monthly") {
            if (ran) { bg="#E8F5E9"; rs="<span style=\"color:#388E3C\">&#10003;</span> " (last_ts!="" ? last_ts : "Ran"); host_ran++ }
            else { bg="#F5F5F5"; rs="&#8505; Monthly - normal" }
        } else {
            if (ran) { bg="#E8F5E9"; rs="<span style=\"color:#388E3C\">&#10003;</span> " (last_ts!="" ? last_ts : "Ran"); host_ran++ }
            else {
                bg="#FFEBEE"; rs="<span style=\"color:#C62828\">&#10007;</span> Not detected"
                if (cat=="hourly" || cat=="minutely") prob_hourly=prob_hourly "##" host "|" cmd
                else if (cat=="daily") prob_daily=prob_daily "##" host "|" cmd
                else if (cat=="weekly") prob_weekly=prob_weekly "##" host "|" cmd
            }
        }

        host_total++
        table_rows=table_rows "<tr style=\"background:" bg "\"><td style=\"padding:6px 8px\">" user "</td><td style=\"padding:6px 8px;font-family:monospace;font-size:12px\">" schedule "</td><td style=\"padding:6px 8px\">" freq "</td><td style=\"padding:6px 8px;font-family:monospace;font-size:12px;max-width:400px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap\">" cmd "</td><td style=\"padding:6px 8px\">" rs "</td></tr>"
    }

    END {
        if (host_ran==host_total) { col="#388E3C"; badge=host_ran"/"host_total" ran"; icon="&#10003;" }
        else if (host_ran>0) { col="#F57C00"; badge=host_ran"/"host_total" ran"; icon="&#9888;" }
        else { col="#9E9E9E"; badge="0/"host_total" not detected"; icon="&#10007;" }
        print "HTML_BLOCK"
        print "<div style=\"margin-bottom:16px;border:1px solid #ddd;border-radius:4px\">"
        print "  <div style=\"padding:10px 14px;background:#f5f5f5;display:flex;justify-content:space-between;align-items:center;font-weight:bold\"><span>" icon " " host "</span><span style=\"padding:2px 10px;border-radius:10px;font-size:12px;color:white;background:" col "\">" badge "</span></div>"
        print "  <div><table style=\"width:100%;border-collapse:collapse;font-size:13px\">"
        print "    <tr><th style=\"background:#1976D2;color:white;padding:8px;text-align:left\">User</th><th style=\"background:#1976D2;color:white;padding:8px;text-align:left\">Schedule</th><th style=\"background:#1976D2;color:white;padding:8px;text-align:left\">Frequency</th><th style=\"background:#1976D2;color:white;padding:8px;text-align:left\">Command</th><th style=\"background:#1976D2;color:white;padding:8px;text-align:left\">Last Run</th></tr>"
        print "    " table_rows
        print "  </table></div></div>"
        print "STATS:" host_ran ":" host_total ":" prob_daily ":" prob_hourly ":" prob_weekly
    }
    ' "$OUTFILE" "$OUTFILE")

    STATS_LINE=$(echo "$RESULT" | grep "^STATS:")
    H_RAN=$(echo "$STATS_LINE" | cut -d: -f2)
    H_TOTAL=$(echo "$STATS_LINE" | cut -d: -f3)
    H_PROB_DAILY=$(echo "$STATS_LINE" | cut -d: -f4)
    H_PROB_HOURLY=$(echo "$STATS_LINE" | cut -d: -f5)
    H_PROB_WEEKLY=$(echo "$STATS_LINE" | cut -d: -f6)

    H_NOTRAN=$((H_TOTAL - H_RAN))
    TOTAL_RAN=$((TOTAL_RAN + H_RAN))
    TOTAL_NOTRAN=$((TOTAL_NOTRAN + H_NOTRAN))

    [ -n "$H_PROB_DAILY" ]  && PROB_DAILY="$PROB_DAILY$H_PROB_DAILY"
    [ -n "$H_PROB_HOURLY" ] && PROB_HOURLY="$PROB_HOURLY$H_PROB_HOURLY"
    [ -n "$H_PROB_WEEKLY" ] && PROB_WEEKLY="$PROB_WEEKLY$H_PROB_WEEKLY"

    echo "$RESULT" | grep -v "^STATS:" | grep -v "^HTML_BLOCK$" >> "$DETAIL_HTML"

done <<< "$HOST_LIST"

# Executive summary
EXEC_SUMMARY=""
build_summary_items() {
    local items="$1"
    echo "$items" | tr '##' '\n' | grep "|" | sort -u | while IFS='|' read -r hst cmd; do
        echo "<li><b>$hst</b>: $cmd</li>"
    done
}

if [ -n "$PROB_HOURLY" ]; then
    EXEC_SUMMARY="${EXEC_SUMMARY}<div style='margin-bottom:10px'><b style='color:#C62828'>&#10007; Hourly/Minutely &mdash; Not Detected:</b><ul style='margin:4px 0 0 0;padding-left:20px'>"
    EXEC_SUMMARY="${EXEC_SUMMARY}$(build_summary_items "$PROB_HOURLY")"
    EXEC_SUMMARY="${EXEC_SUMMARY}</ul></div>"
fi
if [ -n "$PROB_DAILY" ]; then
    EXEC_SUMMARY="${EXEC_SUMMARY}<div style='margin-bottom:10px'><b style='color:#E65100'>&#9888; Daily &mdash; Not Detected:</b><ul style='margin:4px 0 0 0;padding-left:20px'>"
    EXEC_SUMMARY="${EXEC_SUMMARY}$(build_summary_items "$PROB_DAILY")"
    EXEC_SUMMARY="${EXEC_SUMMARY}</ul></div>"
fi
if [ -n "$PROB_WEEKLY" ]; then
    EXEC_SUMMARY="${EXEC_SUMMARY}<div style='margin-bottom:10px'><b style='color:#F9A825'>&#9888; Weekly &mdash; Not Detected (7d):</b><ul style='margin:4px 0 0 0;padding-left:20px'>"
    EXEC_SUMMARY="${EXEC_SUMMARY}$(build_summary_items "$PROB_WEEKLY")"
    EXEC_SUMMARY="${EXEC_SUMMARY}</ul></div>"
fi
[ -z "$EXEC_SUMMARY" ] && EXEC_SUMMARY="<p style='color:#388E3C;margin:0'>&#10003; All expected jobs ran successfully.</p>"

# Build HTML report
cat > "$REPORT" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
</head>
<body style="font-family:Arial,sans-serif;max-width:1200px;margin:auto;padding:20px;color:#333">
HTMLEOF

cat >> "$REPORT" << HTMLEOF
<h2 style="border-bottom:3px solid #1976D2;padding-bottom:8px">CronFetcher Report &nbsp;<span style="font-size:14px;font-weight:normal;color:#666">$DATE</span></h2>

<div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:20px">
  <div style="padding:10px 16px;border-radius:8px;color:white;text-align:center;min-width:90px;background:#1976D2"><b style="display:block;font-size:26px">$TOTAL_HOSTS</b>Total Hosts</div>
  <div style="padding:10px 16px;border-radius:8px;color:white;text-align:center;min-width:90px;background:#388E3C"><b style="display:block;font-size:26px">$SUCCESS_HOSTS</b>With Cron</div>
  <div style="padding:10px 16px;border-radius:8px;color:white;text-align:center;min-width:90px;background:#D32F2F"><b style="display:block;font-size:26px">$FAILED_HOSTS</b>Unreachable</div>
  <div style="padding:10px 16px;border-radius:8px;color:white;text-align:center;min-width:90px;background:#7B1FA2"><b style="display:block;font-size:26px">$TOTAL_JOBS</b>Total Jobs</div>
  <div style="padding:10px 16px;border-radius:8px;color:white;text-align:center;min-width:90px;background:#00796B"><b style="display:block;font-size:26px">$TOTAL_RAN</b>Ran</div>
  <div style="padding:10px 16px;border-radius:8px;color:white;text-align:center;min-width:90px;background:#E65100"><b style="display:block;font-size:26px">$TOTAL_NOTRAN</b>Not Detected</div>
</div>

<div style="background:#FFF8E1;border-left:4px solid #F57C00;padding:14px 18px;margin-bottom:24px;border-radius:4px">
  <b style="font-size:15px">Executive Summary</b><br><br>
  $EXEC_SUMMARY
</div>
HTMLEOF

cat "$DETAIL_HTML" >> "$REPORT"

cat >> "$REPORT" << 'HTMLEOF'
<p style="color:#999;font-size:11px;margin-top:20px">
  * <span style="color:#C62828">&#10007;</span> Not detected: No execution log found within the expected window (minutely/hourly=24h, daily=24h, weekly=7d, monthly=35d).<br>
  * &#8505; Awaiting reboot: @reboot jobs only run on system restart.<br>
  * &#8505; Monthly (normal): Monthly job not detected within 35-day window; this may be expected.
</p>
</body></html>
HTMLEOF

echo "[$(date '+%H:%M:%S')] Report generated."

# =============================================================================
# Send email
# =============================================================================
SUBJECT="[CronFetcher] Report $DATE | $SUCCESS_HOSTS hosts / $TOTAL_JOBS jobs"
MAIL_TMP="$TMPDIR/mail.txt"

{
    echo "From: $MAIL_FROM"
    echo "To: $MAIL_TO"
    echo "Subject: $SUBJECT"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/html; charset=UTF-8"
    echo ""
    cat "$REPORT"
} > "$MAIL_TMP"

curl --silent --url "smtp://$SMTP_HOST:$SMTP_PORT" \
     --mail-from "$MAIL_FROM" \
     --mail-rcpt "$MAIL_TO" \
     --upload-file "$MAIL_TMP"

echo "[$(date '+%H:%M:%S')] Email sent to: $MAIL_TO"

# rm -rf "$TMPDIR"
echo "[$(date '+%H:%M:%S')] Done."
