# Cron Directory

This directory contains cron job definitions and boot scripts for the BMW CarData plugin.

## Files

### crontab
Standard cron job definitions that run periodically.

**Status:** Currently not used - periodic tasks handled by `cron.30min` instead.

**Execution context:**
- User: `loxberry`
- Installed to: `/etc/cron.d/`
- Format: Standard crontab format with username field
- Note: Kept for future custom cron entries if needed

### cron.30min
Script executed every 30 minutes for token refresh.

**What it does:**
1. Runs `token-manager.pl check`
2. Refreshes OAuth tokens if they expire within 5 minutes
3. Logs to `token-refresh.log`

**Execution context:**
- User: `loxberry`
- Frequency: Every 30 minutes
- Logs: `/opt/loxberry/log/plugins/loxberry-bmw-cardata/token-refresh.log`

**Why every 30 minutes:**
- Access/ID tokens expire after 1 hour
- Refresh margin is 5 minutes
- 30-minute interval ensures timely refresh
- Prevents token expiration during bridge operation

### cron.reboot
Script executed at system startup.

**What it does:**
1. Checks if OAuth tokens exist (`tokens.json`)
2. Checks if plugin configuration exists (`config.json`)
3. If both exist: Starts `bmw-cardata-bridge.pl` daemon
4. Verifies daemon started successfully
5. Logs all actions to `reboot.log`

**Execution context:**
- User: `loxberry` (not root!)
- Timing: At system boot, after LoxBerry services are started
- Logs: `/opt/loxberry/log/plugins/loxberry-bmw-cardata/reboot.log`

**Important:**
- Script must exit cleanly and quickly
- Should not block boot process
- Gracefully handles missing prerequisites

## LoxBerry Cron Script Types

LoxBerry provides specialized cron scripts for different intervals:

- **cron.reboot** - Runs at system boot
- **cron.01min** - Runs every minute
- **cron.03min** - Runs every 3 minutes
- **cron.05min** - Runs every 5 minutes
- **cron.10min** - Runs every 10 minutes
- **cron.15min** - Runs every 15 minutes
- **cron.30min** - Runs every 30 minutes ✓ (used for token refresh)
- **cron.hourly** - Runs every hour
- **cron.daily** - Runs daily
- **cron.weekly** - Runs weekly
- **cron.monthly** - Runs monthly

**Benefits over traditional crontab:**
- Simpler - no cron syntax needed
- Automatic execution as `loxberry` user
- LoxBerry manages scheduling
- Easier to maintain

**Why cron.reboot instead of daemon/?**

LoxBerry supports two approaches for boot-time daemons:
1. **daemon/daemon** - Runs as `root`, requires `su`
2. **cron.reboot** - Runs as `loxberry` ✓ (preferred)

This plugin uses `cron.reboot` because:
- Simpler - no user switching needed
- Safer - correct permissions from start
- Recommended by LoxBerry documentation

## Variable Replacement

LoxBerry replaces `REPLACELBPPLUGINDIR` with actual plugin directory name during installation.

**Before installation:**
```bash
PLUGINNAME=REPLACELBPPLUGINDIR
```

**After installation:**
```bash
PLUGINNAME=loxberry-bmw-cardata
```

## Testing

### Test cron.reboot manually:
```bash
# Run as loxberry user
sudo -u loxberry /path/to/cron/cron.reboot

# Check log
tail -f /opt/loxberry/log/plugins/loxberry-bmw-cardata/reboot.log

# Verify daemon started
ps aux | grep bmw-cardata-bridge
cat /opt/loxberry/data/plugins/loxberry-bmw-cardata/bridge.pid
```

### Test cron.30min:
```bash
# Run manually
sudo -u loxberry /path/to/cron/cron.30min

# Check log
tail -f /opt/loxberry/log/plugins/loxberry-bmw-cardata/token-refresh.log

# Verify token refresh works
sudo -u loxberry /opt/loxberry/bin/plugins/loxberry-bmw-cardata/token-manager.pl status
```

## Logs

All cron-related logs are written to:
- **Reboot log**: `/opt/loxberry/log/plugins/loxberry-bmw-cardata/reboot.log`
- **Token refresh log**: `/opt/loxberry/log/plugins/loxberry-bmw-cardata/token-refresh.log`
- **Bridge log**: `/opt/loxberry/log/plugins/loxberry-bmw-cardata/bridge.log`

## See Also

- `../bin/bmw-cardata-bridge.pl` - The daemon process started by cron.reboot
- `../bin/token-manager.pl` - Token refresh script called by crontab
- `../bin/bridge-control.sh` - Manual daemon control
