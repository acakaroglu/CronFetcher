# CronFetcher

**Agentless cron job monitoring for Red Hat Satellite / Foreman managed infrastructure.**

CronFetcher discovers all cron jobs across your managed hosts, tracks their execution, and delivers a daily HTML report via email — no agents, no databases, no external dependencies.

![Report Example](screenshots/report-example.png)

## How It Works

```
┌─────────────┐     SSH      ┌──────────────┐
│  Satellite  │─────────────▶│  Managed     │
│  Server     │  crontab -l  │  Hosts       │
│             │◀─────────────│  (100s)      │
│  cronfetcher│              │              │
│  .sh        │   inject     │  cronfetcher │
│             │─────────────▶│  .log        │
│             │   cat log    │              │
│             │◀─────────────│              │
└──────┬──────┘              └──────────────┘
       │
       │ HTML Report
       ▼
    📧 Email
```

### Three Phases

1. **Scan** — SSH into each host, collect all crontabs (`crontab -l` for every user)
2. **Log** — Read execution logs to determine which jobs actually ran
3. **Report** — Generate an HTML report with per-host, per-job status and email it

### Two Log Sources

| Source | How | Accuracy |
|--------|-----|----------|
| **CronFetcher inject** (recommended) | Appends logging to each cron line; writes to `/var/log/cronfetcher.log` | Exact timestamp, per-job tracking, OK/FAIL status |
| **System fallback** | Parses `journalctl -u crond` and `/var/log/cron*` | Basic detection only (no timestamps, no fail tracking) |

## Quick Start

### 1. Clone & Configure

```bash
git clone https://github.com/youruser/cronfetcher.git /opt/cronfetcher
cd /opt/cronfetcher
cp cronfetcher.conf.example cronfetcher.conf
vim cronfetcher.conf   # Set SSH key, email, SMTP, etc.
```

### 2. Test with a Single Host

```bash
# Run a full report (uses hammer or host file for discovery)
bash cronfetcher.sh

# Or inject logging on a single host first
bash cronfetcher.sh --inject "myhost|10.0.0.1"
```

### 3. Deploy Inject Across All Hosts

```bash
# Inject logging into all managed hosts
bash cronfetcher.sh --inject-all

# Wait 15-30 minutes for cron jobs to run, then generate report
bash cronfetcher.sh
```

### 4. Schedule Daily Reports

```bash
# Add to Satellite server's crontab
0 7 * * * /opt/cronfetcher/cronfetcher.sh
```

## Usage

```
cronfetcher.sh                          Run full scan + report + email
cronfetcher.sh --inject  hostname|ip    Inject logging on a single host
cronfetcher.sh --rollback hostname|ip   Remove injection from a single host
cronfetcher.sh --inject-all             Inject logging on all managed hosts
cronfetcher.sh --rollback-all           Remove injection from all managed hosts
cronfetcher.sh --help                   Show help
```

## Configuration

All settings live in `cronfetcher.conf`:

```bash
# SSH
SSH_KEY="/var/lib/foreman-proxy/ssh/id_rsa_foreman_proxy"
SSH_USER="satellite-automation"

# Email
MAIL_TO="admin@example.com"
MAIL_FROM="cronfetcher@example.com"
SMTP_HOST="10.0.0.1"
SMTP_PORT=25

# Host discovery: "hammer" (Satellite API) or "file" (static list)
HOST_SOURCE="hammer"

# Cache hammer results for 24h (avoids slow API calls on every run)
HAMMER_CACHE_TTL=86400
```

### Static Host File

If not using Satellite/Foreman, set `HOST_SOURCE="file"` and create a host file:

```
# /etc/cronfetcher/hosts.txt
webserver1|10.0.1.10
dbserver1|10.0.1.20
appserver1|10.0.1.30
```

## How Inject Works

CronFetcher's inject mechanism appends a logging snippet to each cron line:

```
# Before inject:
* * * * * /usr/local/bin/cleanup.sh

# After inject:
* * * * * /usr/local/bin/cleanup.sh ; rc=$?; if [ $rc -eq 0 ]; then st=OK; else st=FAIL; fi; echo "$(date '+%Y-%m-%d %H:%M:%S')|root|/usr/local/bin/cleanup.sh|$st" >> /var/log/cronfetcher.log
```

**Safety features:**
- Original crontab is backed up to `/var/lib/cronfetcher_backup/`
- Already-injected lines are skipped (safe to run multiple times)
- Full rollback with `--rollback` or `--rollback-all`
- Uses `;` instead of `&&` — logs both success (OK) and failure (FAIL)

**Log format:**
```
2026-02-28 00:43:01|root|/usr/local/bin/cleanup.sh|OK
2026-02-28 00:44:01|root|/usr/local/bin/cleanup.sh|FAIL
```

## Report Features

The HTML email report includes:

- **KPI dashboard** — Total hosts, jobs, success/fail counts at a glance
- **Executive summary** — Highlights jobs that didn't run when expected
- **Per-host breakdown** — Expandable cards with job-level detail
- **Frequency detection** — Translates cron schedules to human-readable format
- **Last run timestamp** — Shows exact last execution time (with inject)
- **Frequency-aware windows** — Checks appropriate time windows per job type:
  - Minutely/Hourly: last 24 hours
  - Daily: last 24 hours
  - Weekly: last 7 days
  - Monthly: last 35 days

## Requirements

- **Satellite/Foreman server** (or any Linux host with SSH access to managed hosts)
- **SSH key-based authentication** to managed hosts
- **sudo access** on managed hosts (for `crontab -l -u` and log reading)
- **curl** (for SMTP email delivery)
- **bash 4+**, awk, sed, grep (standard Linux tools)

## Project Structure

```
cronfetcher/
├── cronfetcher.sh          # Main script
├── inject_helper.sh        # Remote inject/rollback helper
├── cronfetcher.conf        # Configuration (git-ignored)
├── cronfetcher.conf.example # Example configuration
├── README.md
├── LICENSE
└── .gitignore
```

## Roadmap

- [ ] Parallel batch limiting (reduce SSH connection storms)
- [ ] FAIL status highlighting in report (separate color for ran-but-failed)
- [ ] Log rotation for cronfetcher.log on remote hosts
- [ ] Web dashboard alternative to email reports
- [ ] Support for Ansible/AWX as host discovery source

## License

MIT License — see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue first to discuss what you'd like to change.
