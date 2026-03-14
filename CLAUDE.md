# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LoxBerry plugin that bridges BMW's CarData MQTT streaming interface with the LoxBerry MQTT Gateway, enabling Loxone home automation integration with real-time BMW vehicle data (door status, battery level, GPS, tire pressure, etc.).

- **Perl** is the primary language (LoxBerry plugin standard)
- **Node.js** is used only for release automation (not part of plugin runtime)
- **Commit format**: Use conventional commits (`feat:`, `fix:`, `docs:`, `improve:`, `type(ci):`) for changelog generation

## Architecture

The plugin has six components connected in a pipeline:

```
BMW CarData API  -->  OAuth Scripts  -->  tokens.json  -->  MQTT Bridge  -->  LoxBerry MQTT Gateway  -->  Loxone
                      (bin/*.pl)          (data/)           (daemon)          (local broker)
```

### Multi-Account Architecture

The plugin supports multiple BMW accounts (multi-tenant). Each account is stored in its own subdirectory under `data/accounts/{account-id}/`. All bin scripts require `--account <id>` parameter. One bridge daemon process runs per account.

```
data/accounts/
├── martin/           # Account "Martin's BMW"
│   ├── config.json
│   ├── tokens.json
│   ├── device_code.json  (temporary)
│   ├── pkce.json         (temporary)
│   └── bridge.pid
└── sarah/            # Account "Sarah's BMW"
    ├── config.json
    ├── tokens.json
    └── bridge.pid
```

### Component Files

| Component | File | Purpose |
|-----------|------|---------|
| Web Interface | `webfrontend/htmlauth/index.cgi` | CGI script: account management, config forms, OAuth flow UI, bridge control |
| OAuth Init | `bin/oauth-init.pl` | PKCE + device code request to BMW API. `--account <id>` required |
| OAuth Poll | `bin/oauth-poll.pl` | Polls BMW for tokens after user authorizes. `--account <id>` required |
| Token Manager | `bin/token-manager.pl` | Commands: `check`, `refresh`, `status`. `--account <id>` required |
| MQTT Bridge | `bin/bmw-cardata-bridge.pl` | Daemon: connects to BMW MQTTS per account. `--account <id>` required |
| Bridge Control | `bin/bridge-control.sh` | `--account <id> {start|stop|restart|status|logs}` or `{start-all|stop-all}` |

### Data Flow and Separation of Concerns

- **Token Manager** (cron job) is solely responsible for refreshing tokens. It writes to `data/accounts/<id>/tokens.json`.
- **MQTT Bridge** (daemon) does NOT refresh tokens. It monitors `tokens.json` every 2.5 minutes and reconnects when it detects a new `id_token`.
- **Web Interface** calls the bin scripts via `system()` with `--account` parameter and reads JSON files for status display.
- **Cron jobs** loop over all `data/accounts/*/` directories to manage all accounts.

### Key Constants (from source code)

| Constant | Value | Location |
|----------|-------|----------|
| Token refresh margin | 15 min (900s) before expiry | `bin/token-manager.pl` |
| Bridge token check interval | 2.5 min (150s) | `bin/bmw-cardata-bridge.pl` |
| Cron token check | Every 10 min | `cron/cron.10min` |
| Reconnect backoff | 10s initial, doubles up to 24h max | `bin/bmw-cardata-bridge.pl` |
| Default stream port | 9000 (web UI default) | `webfrontend/htmlauth/index.cgi` |
| Default MQTT prefix | `bmw-{account-id}` | `webfrontend/htmlauth/index.cgi` |

### Data Storage (per account in `data/accounts/{account-id}/`)

- `config.json` - Account config (account_name, client_id, stream_host/port/username, VINs, mqtt_topic_prefix)
- `tokens.json` - OAuth tokens (access_token, id_token, refresh_token, gcid, expires_at, refresh_expires_at)
- `device_code.json` - Temporary: during OAuth device code flow
- `pkce.json` - Temporary: PKCE code_verifier during OAuth flow
- `bridge.pid` - PID file for bridge daemon

### Migration (v1.x single-account to v2.x multi-account)

`postupgrade.sh` detects files in the flat `data/` root layout and migrates them to `data/accounts/default/`.

## LoxBerry Path Placeholders (CRITICAL)

**NEVER use absolute paths in plugin code.** LoxBerry replaces these placeholders during installation:

| Placeholder | Installed path |
|-------------|---------------|
| `REPLACELBPBINDIR` | `/opt/loxberry/bin/plugins/PLUGINNAME` |
| `REPLACELBPDATADIR` | `/opt/loxberry/data/plugins/PLUGINNAME` |
| `REPLACELBPLOGDIR` | `/opt/loxberry/log/plugins/PLUGINNAME` |
| `REPLACELBPCONFIGDIR` | `/opt/loxberry/config/plugins/PLUGINNAME` |
| `REPLACELBPTEMPLDIR` | `/opt/loxberry/templates/plugins/PLUGINNAME` |
| `REPLACELBPHTMLAUTHDIR` | `/opt/loxberry/webfrontend/htmlauth/plugins/PLUGINNAME` |
| `REPLACELBPPLUGINDIR` | Plugin directory name (e.g., `bmw-cardata`) |

**In Perl CGI scripts**, use LoxBerry variables instead: `$lbpbindir`, `$lbpdatadir`, `$lbplogdir`, `$lbpconfigdir`, `$lbptemplatedir`

## Directory Structure

```
webfrontend/htmlauth/  - Web interface (CGI, authenticated)
templates/             - HTML templates + lang/ translations (language_de.ini, language_en.ini)
bin/                   - Perl scripts + bridge-control.sh (not web-accessible)
data/accounts/         - Per-account runtime data (tokens, config, PID) (persists across upgrades)
config/                - Plugin config files (persists across upgrades)
cron/                  - cron.reboot (start all bridges), cron.10min (refresh all tokens)
dev/                   - Local development environment (mock LoxBerry, dev server)
.github/release.js     - Automated release script
```

## Important Constraints

- **Path Placeholders**: ALWAYS use `REPLACE*` placeholders or LoxBerry variables, NEVER hardcoded paths
- **One MQTT Connection**: BMW allows only ONE connection per GCID simultaneously
- **BMW MQTT Auth**: Username = `stream_username` (from config), Password = `id_token` (NOT access_token)
- **Token Timing**: Access/ID tokens valid 1 hour, refresh token valid 2 weeks
- **Cron User**: All cron jobs run as `loxberry` user, not root
- **Perl Dependencies**: `AnyEvent::MQTT` installed locally to `bin/perl5/` via cpanm in `postinstall.sh`
- **Bridge uses `use lib "REPLACELBPBINDIR/perl5/lib/perl5"`** to find locally-installed modules

## Development Commands

### Release
```bash
npm run release:patch    # Patch release (0.0.x)
npm run release:minor    # Minor release (0.x.0)
npm run release:major    # Major release (x.0.0)
npm run pre:patch        # Prerelease (0.0.x-rc)
```

### Create Plugin ZIP
```bash
./create-plugin-zip.sh   # Linux/macOS/Git Bash
```

### Local Development (Windows)
```bash
cd dev && ./run-dev.bat          # Static HTML output, opens in browser
cd dev && ./start-dev.bat        # HTTP server at http://localhost:8080/ with CGI
```

### Testing on LoxBerry
```bash
bin/oauth-init.pl --account myaccount                    # Start OAuth device code flow
bin/oauth-poll.pl --account myaccount                    # Poll for tokens after user authorizes
bin/token-manager.pl --account myaccount check           # Check and refresh tokens if needed
bin/token-manager.pl --account myaccount refresh --force # Force token refresh
bin/token-manager.pl --account myaccount status          # Show token status
bin/bmw-cardata-bridge.pl --account myaccount            # Run bridge in foreground (debug)
bin/bmw-cardata-bridge.pl --account myaccount --daemon   # Run bridge as daemon
bin/bridge-control.sh --account myaccount status         # Check bridge status
bin/bridge-control.sh start-all                          # Start all account bridges
bin/bridge-control.sh stop-all                           # Stop all account bridges
```

## Local Dev Environment

`dev/LoxBerryMock.pm` mocks `LoxBerry::System`, `LoxBerry::Web`, `LoxBerry::JSON`, `LoxBerry::Log`, `LoxBerry::IO`. `dev/index-dev.cgi` is the dev version of the web interface that uses these mocks.

**Simulate states** by creating/deleting files in `data/accounts/{account-id}/`:
- Delete `tokens.json` = not authenticated
- Create `tokens.json` with `expires_at: 9999999999` = authenticated
- Create `device_code.json` = OAuth flow in progress
- Create/delete account directories to simulate multi-account scenarios

## Web Interface Structure

The CGI script (`index.cgi`) uses:
- `HTML::Template` with template at `templates/index.html`
- Language files loaded via `LoxBerry::Web::readlanguage()` from `templates/lang/`
- `LoxBerry::Web::lbheader()`/`lbfooter()` for page chrome
- Action routing via `$cgi->param('action')` dispatching to `handle_*` subs
- Account routing via `$cgi->param('account')` selecting the active account
- Account selector bar at top with create/delete controls
- Two pages: `main` (config + OAuth + bridge status) and `logs`

## LoxBerry Perl Conventions

```perl
use LoxBerry::System;    # plugindata(), $lbpbindir, $lbpdatadir, etc.
use LoxBerry::Web;       # readlanguage(), lbheader(), lbfooter(), loglist_html()
use LoxBerry::Log;       # LOGSTART, LOGINF, LOGOK, LOGWARN, LOGERR, LOGCRIT, LOGDEB, LOGEND
use LoxBerry::JSON;      # JSON handling
use LoxBerry::IO;        # mqtt_connectiondetails()
```

- Before doing any plannings or modifications, always check for changes first. I always change files myself to improve the code.
