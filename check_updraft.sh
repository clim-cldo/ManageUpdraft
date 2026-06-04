#!/usr/bin/env bash
# UpdraftPlus backup monitor
# Discovers WordPress installs, checks backup status via wp-cli, alerts via email.

# ──────────────────────────── CONFIG ────────────────────────────
SEARCH_PATHS=(
    "/home/*/public_html"
    "/home/*/www"
    "/var/www/*/public_html"
    "/var/www/html"
)

ALERT_EMAIL="admin@example.com"
FROM_EMAIL="backupmonitor@$(hostname -f)"
WP_CLI="/opt/cpanel/ea-php83/root/usr/bin/php /usr/local/bin/wp"  # cPanel: use PHP with proc_open enabled
MAX_BACKUP_AGE_DAYS=2            # alert if last backup older than this
LOG_FILE="/var/log/updraft_monitor.log"
SEND_SUMMARY=true                # set false to only email on failures
# ────────────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
NOW=$(date +%s)
DATE_LABEL=$(date '+%Y-%m-%d %H:%M')

declare -a FAILURES=()
declare -a WARNINGS=()
declare -a OK=()
declare -a SKIPPED=()   # no UpdraftPlus

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── find all wp-config.php files under search paths ──────────────
find_wp_installs() {
    local dirs=()
    for pattern in "${SEARCH_PATHS[@]}"; do
        for dir in $pattern; do
            [ -d "$dir" ] || continue
            while IFS= read -r cfg; do
                dirs+=("$(dirname "$cfg")")
            done < <(find "$dir" -maxdepth 3 -name "wp-config.php" 2>/dev/null)
        done
    done
    # deduplicate
    printf '%s\n' "${dirs[@]}" | sort -u
}

# ── check if UpdraftPlus is active in a WP install ───────────────
updraft_active() {
    local path="$1"
    $WP_CLI plugin is-active updraftplus --path="$path" --allow-root 2>/dev/null
}

# ── pull UpdraftPlus options from DB via wp eval (handles PHP serialized data) ──
get_updraft_option() {
    local path="$1"
    $WP_CLI eval '
$opt = get_option("updraftplus");
$history = get_option("updraftplus_backup_history", array());
if (!is_array($opt)) $opt = array();
$opt["backup_history"] = is_array($history) ? $history : array();
echo json_encode($opt);
' --path="$path" --allow-root 2>/dev/null
}

# ── parse a PHP serialized/JSON timestamp field ──────────────────
extract_last_backup_time() {
    local json="$1"
    # last_backup_time is stored as a unix timestamp inside the option
    echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # UpdraftPlus stores last_backup_time as top-level key
    t = d.get('last_backup_time', 0)
    print(int(t))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

extract_last_backup_succeeded() {
    local json="$1"
    echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    history = d.get('backup_history', {})
    if not history:
        print('unknown')
        sys.exit(0)
    # history keys are unix timestamps; find the latest
    latest_ts = max(history.keys(), key=lambda x: float(x))
    entry = history[latest_ts]
    if not isinstance(entry, dict):
        print('unknown')
        sys.exit(0)
    # UpdraftPlus marks failures with a 'failed' key or missing backup components
    if entry.get('failed') or entry.get('jobstatus') == 'failed':
        print('failed')
    else:
        print('ok')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown"
}

# ── format age string ─────────────────────────────────────────────
age_string() {
    local ts="$1"
    [ "$ts" -eq 0 ] && echo "never" && return
    local diff=$(( NOW - ts ))
    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    echo "${days}d ${hours}h ago"
}

# ── send email ────────────────────────────────────────────────────
send_email() {
    local subject="$1"
    local body="$2"
    echo -e "From: $FROM_EMAIL\nTo: $ALERT_EMAIL\nSubject: $subject\n\n$body" \
        | sendmail -t
}

# ═══════════════════════════ MAIN ════════════════════════════════
log "Starting UpdraftPlus backup check"

mapfile -t WP_DIRS < <(find_wp_installs)
log "Found ${#WP_DIRS[@]} WordPress install(s)"

for wp_path in "${WP_DIRS[@]}"; do
    site_label=$(echo "$wp_path" | sed 's|/public_html||; s|/var/www/||; s|/home/||')

    if ! updraft_active "$wp_path"; then
        SKIPPED+=("$site_label")
        log "SKIP  $site_label (UpdraftPlus not active)"
        continue
    fi

    option_json=$(get_updraft_option "$wp_path")

    if [ -z "$option_json" ] || [ "$option_json" = "null" ]; then
        WARNINGS+=("$site_label — could not read UpdraftPlus options")
        log "WARN  $site_label — no option data"
        continue
    fi

    last_ts=$(extract_last_backup_time "$option_json")
    status=$(extract_last_backup_succeeded "$option_json")
    age=$(age_string "$last_ts")

    if [ "$last_ts" -eq 0 ]; then
        WARNINGS+=("$site_label — no backup on record")
        log "WARN  $site_label — no backup on record"
        continue
    fi

    age_days=$(( (NOW - last_ts) / 86400 ))

    if [ "$status" = "failed" ]; then
        FAILURES+=("$site_label — last backup FAILED ($age)")
        log "FAIL  $site_label — last backup failed ($age)"
    elif [ "$age_days" -ge "$MAX_BACKUP_AGE_DAYS" ]; then
        WARNINGS+=("$site_label — last backup $age (older than ${MAX_BACKUP_AGE_DAYS}d threshold)")
        log "WARN  $site_label — stale backup ($age)"
    else
        OK+=("$site_label — OK ($age)")
        log "OK    $site_label ($age)"
    fi
done

# ── build report ──────────────────────────────────────────────────
build_report() {
    local nl=$'\n'
    local report="UpdraftPlus Backup Report — $DATE_LABEL${nl}"
    report+="Host: $(hostname -f)${nl}"
    report+="────────────────────────────────────────${nl}"

    if [ ${#FAILURES[@]} -gt 0 ]; then
        report+="${nl}FAILED (${#FAILURES[@]})${nl}"
        for s in "${FAILURES[@]}"; do report+="  ✗ $s${nl}"; done
    fi

    if [ ${#WARNINGS[@]} -gt 0 ]; then
        report+="${nl}WARNINGS (${#WARNINGS[@]})${nl}"
        for s in "${WARNINGS[@]}"; do report+="  ⚠ $s${nl}"; done
    fi

    if [ ${#OK[@]} -gt 0 ]; then
        report+="${nl}OK (${#OK[@]})${nl}"
        for s in "${OK[@]}"; do report+="  ✓ $s${nl}"; done
    fi

    if [ ${#SKIPPED[@]} -gt 0 ]; then
        report+="${nl}No UpdraftPlus (${#SKIPPED[@]} sites skipped)${nl}"
    fi

    report+="${nl}────────────────────────────────────────${nl}"
    report+="Total monitored: $(( ${#FAILURES[@]} + ${#WARNINGS[@]} + ${#OK[@]} )) | Skipped: ${#SKIPPED[@]}${nl}"
    echo "$report"
}

REPORT=$(build_report)
echo "$REPORT"

# ── send alerts ───────────────────────────────────────────────────
if [ ${#FAILURES[@]} -gt 0 ]; then
    send_email "[ALERT] UpdraftPlus backup FAILURES on $(hostname -f)" "$REPORT"
    log "Alert email sent (failures detected)"
elif [ ${#WARNINGS[@]} -gt 0 ]; then
    send_email "[WARNING] UpdraftPlus backup warnings on $(hostname -f)" "$REPORT"
    log "Warning email sent"
elif $SEND_SUMMARY; then
    send_email "[OK] UpdraftPlus backup summary — $(hostname -f)" "$REPORT"
    log "Summary email sent (all OK)"
fi

log "Check complete. Failures: ${#FAILURES[@]}  Warnings: ${#WARNINGS[@]}  OK: ${#OK[@]}  Skipped: ${#SKIPPED[@]}"
