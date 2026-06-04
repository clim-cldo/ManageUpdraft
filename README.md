# ManageUpdraft — UpdraftPlus Backup Monitor

Monitors all WordPress sites on a VPS, checks UpdraftPlus backup status via wp-cli, and sends email alerts.

## Requirements

- `bash` (4+)
- `wp-cli` — [install guide](https://wp-cli.org/#installing)
- `python3` (for JSON parsing — standard on most VPS)
- `sendmail` (or a compatible MTA like `postfix`)

### Check / install wp-cli

```bash
which wp && wp --info
# If not found:
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp
```

## Setup

1. **Clone/copy** this repo to your VPS (e.g. `/opt/manageupdraft/`)

2. **Edit config** at the top of `check_updraft.sh`:

   ```bash
   ALERT_EMAIL="you@yourdomain.com"   # where to send alerts
   MAX_BACKUP_AGE_DAYS=2              # alert if backup older than this
   SEARCH_PATHS=(                     # adjust to match your VPS layout
       "/home/*/public_html"
       "/var/www/*/public_html"
   )
   ```

3. **Make executable:**
   ```bash
   chmod +x check_updraft.sh
   ```

4. **Test run:**
   ```bash
   sudo bash check_updraft.sh
   ```

5. **Schedule via cron** (runs daily at 7am):
   ```bash
   sudo crontab -e
   ```
   Add:
   ```
   0 7 * * * /opt/manageupdraft/check_updraft.sh >> /var/log/updraft_monitor.log 2>&1
   ```

## Output / Alerts

| Situation | Email sent |
|-----------|-----------|
| Any backup FAILED | Immediate `[ALERT]` email |
| Any backup stale (> threshold) | `[WARNING]` email |
| All OK | Daily `[OK]` summary (disable with `SEND_SUMMARY=false`) |
| Site has no UpdraftPlus | Silently skipped |

## What it checks

1. Discovers all `wp-config.php` files under `SEARCH_PATHS`
2. Skips sites where UpdraftPlus plugin is not active
3. Reads `updraftplus` option from the WordPress DB via wp-cli
4. Checks `last_backup_time` against `MAX_BACKUP_AGE_DAYS`
5. Checks `backup_history` for any failed entries

## Telegram (future)

Replace the `send_email` function call with a `curl` POST to the Telegram Bot API:
```bash
curl -s -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d chat_id="<CHAT_ID>" \
  -d text="$REPORT"
```
