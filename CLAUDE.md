# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a LoxBerry plugin for BMW CarData API integration. The plugin bridges BMW's CarData MQTT interface with the LoxBerry MQTT Gateway, enabling Loxone home automation integration with BMW vehicle data.

**Core Functionality:**
- OAuth 2.0 authentication with BMW CarData API
- Automatic token refresh management
- MQTT message bridging between BMW CarData and LoxBerry MQTT Gateway
- Web interface for configuration and OAuth flow

**References:**
- BMW CarData API: https://bmw-cardata.bmwgroup.com/customer/public/api-documentation
- LoxBerry MQTT Gateway: https://wiki.loxberry.de/konfiguration/widget_help/widget_mqtt
- Plugin Developer Guide: https://wiki.loxberry.de/konfiguration/widget_help/widget_mqtt/mqtt_gateway/mqtt_gateway_for_plugin_developers

## LoxBerry Plugin Architecture

LoxBerry plugins are installed to `/opt/loxberry/` with the following structure:

### Directory Structure (Development vs. Installed)

**Development (this repo):**
```
loxberry-bmw-cardata/
├── webfrontend/htmlauth/     → /opt/loxberry/webfrontend/htmlauth/plugins/loxberry-bmw-cardata/
├── templates/                → /opt/loxberry/templates/plugins/loxberry-bmw-cardata/
├── bin/                      → /opt/loxberry/bin/plugins/loxberry-bmw-cardata/
├── data/                     → /opt/loxberry/data/plugins/loxberry-bmw-cardata/
├── config/                   → /opt/loxberry/config/plugins/loxberry-bmw-cardata/
├── cron/                     → Installed to /etc/cron.d/
├── daemon/                   → Boot-time daemon scripts
├── icons/                    → Plugin icons
├── uninstall/                → Uninstallation scripts
├── plugin.cfg                → Plugin metadata
├── release.cfg               → Auto-update configuration (releases)
├── prerelease.cfg            → Auto-update configuration (prereleases)
├── preinstall.sh             → Pre-installation hook
├── postinstall.sh            → Post-installation hook
├── preupgrade.sh             → Pre-upgrade hook
└── postupgrade.sh            → Post-upgrade hook
```

### Key Directories

- **webfrontend/htmlauth/**: Web interface requiring authentication
  - `index.cgi`: Main web interface (Perl CGI)
  - CGI scripts have access to LoxBerry modules

- **templates/**: HTML templates and language files
  - `index.html`: Main HTML template
  - `lang/language_de.ini`, `lang/language_en.ini`: Translations

- **bin/**: Executable scripts (daemon processes, background workers)
  - Not accessible via web
  - Use for OAuth token refresh daemon, MQTT bridge script

- **data/**: Plugin data storage
  - Store OAuth tokens here (e.g., `tokens.json`)
  - Persists across plugin upgrades

- **config/**: Configuration files
  - Store plugin settings (e.g., `plugin.json`)
  - Persists across plugin upgrades

- **cron/**: Cron job definitions and boot scripts
  - `crontab`: Traditional cron format (currently unused, kept for future use)
  - `cron.reboot`: Executed at system boot - starts MQTT bridge daemon
  - `cron.30min`: Executed every 30 minutes - refreshes OAuth tokens
  - All scripts run as 'loxberry' user
  - LoxBerry manages scheduling automatically

- **daemon/**: Boot-time daemon scripts (DEPRECATED - use cron.reboot instead)
  - Legacy approach: `daemon` script runs as 'root' at boot
  - Modern approach: Use `cron/cron.reboot` which runs as 'loxberry'

- **icons/**: Plugin icons for LoxBerry UI

- **uninstall/**: Uninstallation scripts
  - `uninstall`: Executed when plugin is uninstalled
  - Should stop running daemons gracefully
  - Can optionally clean up data files

## LoxBerry Plugin Lifecycle Scripts

- **preinstall.sh**: Runs before plugin installation
- **postinstall.sh**: Runs after plugin installation
- **preupgrade.sh**: Runs before plugin upgrade
- **postupgrade.sh**: Runs after plugin upgrade

## Key Technologies

- **Perl**: Primary language for LoxBerry plugins
  - Uses LoxBerry::System, LoxBerry::Web modules
  - CGI for web interface
  - HTML::Template for templating
- **Node.js**: Used for release automation only (not part of plugin runtime)

## Release Management

The project uses an automated release system powered by Node.js scripts:

### Release Commands
```bash
npm run release:major    # Major release (x.0.0)
npm run release:minor    # Minor release (0.x.0)
npm run release:patch    # Patch release (0.0.x)
npm run pre:major        # Major prerelease (x.0.0-rc)
npm run pre:minor        # Minor prerelease (0.x.0-rc)
npm run pre:patch        # Patch prerelease (0.0.x-rc)
```

### Release Process
The `.github/release.js` script automates:
1. Git environment validation (must be clean)
2. Version bumping in package.json
3. Updating plugin.cfg with new version
4. Updating release.cfg or prerelease.cfg with version and archive URL
5. Changelog generation from git commits (uses [conventional commits](https://github.com/lob/generate-changelog))
6. Git commit, tag creation, and push to remote

### Release Configuration
In package.json, you can configure:
```json
{
  "config": {
    "release": {
      "additionalNodeModules": ["bin"],  // Additional package.json locations
      "additionalCommands": [
        {
          "command": "npm run build",
          "gitFiles": "webfrontend templates"  // Files to stage after command
        }
      ]
    }
  }
}
```

## MQTT Gateway Integration

LoxBerry provides MQTT infrastructure that this plugin uses to communicate with BMW CarData.

### MQTT Connection Methods

**1. Get MQTT Server Details (Recommended for Perl):**
```perl
use LoxBerry::IO;
my $creds = LoxBerry::IO::mqtt_connectiondetails();
# Returns: brokeraddress, brokerport, brokeruser, brokerpass, udpinport
```

**2. Publish MQTT Messages via UDP:**
```perl
# Easiest method - send to UDP in-port
# Format: topic payload
use IO::Socket::INET;
my $sock = IO::Socket::INET->new(
    PeerAddr => 'localhost',
    PeerPort => $creds->{udpinport},
    Proto => 'udp'
);
$sock->send("topic/path message_payload");
```

**3. Direct MQTT Connection:**
```perl
use Net::MQTT::Simple;
my $mqtt = Net::MQTT::Simple->new($creds->{brokeraddress});
$mqtt->publish("topic/path", "message_payload");
```

### Plugin-Specific MQTT Configuration Files

Place in plugin directory for MQTT Gateway integration:
- **mqtt_subscriptions.cfg**: Custom MQTT topic subscriptions
- **mqtt_conversions.cfg**: Custom message conversions
- **mqtt_resetaftersend.cfg**: Topics that should reset after sending

## BMW CarData Integration

### OAuth 2.0 Device Code Flow

BMW CarData uses **OAuth 2.0 Device Authorization Grant** (RFC 8628) instead of traditional redirect-based OAuth.

**Base URL**: `https://customer.bmwgroup.com`

#### Step 1: Generate Client ID
- Create via BMW CarData Customer Portal
- Client ID example: `cj5b3499-4918-40x6-a232-f4112f837d72`

#### Step 2: Subscribe to Services
Required scopes in portal:
- **cardata:api:read** - For REST API access
- **cardata:streaming:read** - For MQTT streaming

#### Step 3: Device Code Flow

**3.1: Request Device Code**
```bash
POST /gcdm/oauth/device/code
Content-Type: application/x-www-form-urlencoded

client_id=<your_client_id>
response_type=device_code
scope=authenticate_user openid cardata:streaming:read cardata:api:read
code_challenge=<SHA256_hash_of_code_verifier>
code_challenge_method=S256
```

Response contains:
- `user_code` - User enters this in browser
- `device_code` - Use for polling tokens
- `verification_uri` - URL user visits to authorize
- `verification_uri_complete` - URL with pre-filled code
- `interval` - Minimum polling interval (seconds)
- `expires_in` - Code lifetime (seconds)

**3.2: User Authorization**
- Direct user to `verification_uri_complete` (easiest)
- User logs in with BMW credentials and authorizes device

**3.3: Poll for Tokens**
```bash
POST /gcdm/oauth/token
Content-Type: application/x-www-form-urlencoded

client_id=<your_client_id>
device_code=<device_code_from_step_1>
grant_type=urn:ietf:params:oauth:grant-type:device_code
code_verifier=<original_code_verifier>
```

Response contains three tokens:
- **access_token** - For CarData REST API calls (valid 1 hour)
- **id_token** - For MQTT streaming authentication (valid 1 hour)
- **refresh_token** - To refresh both tokens (valid 2 weeks / 1,209,600 seconds)
- **gcid** - User's unique identifier

#### Step 4: Token Refresh

**Before access_token/id_token expires (within 1 hour), refresh:**
```bash
POST /gcdm/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
refresh_token=<current_refresh_token>
client_id=<your_client_id>
```

Returns new set of all three tokens with reset expiry timers.

**Important:**
- Refresh token expires after 2 weeks - must re-run device code flow if expired
- If client unsubscribed from services, refresh token becomes invalid immediately
- Use cron job to refresh tokens before expiry

### MQTT Streaming Integration

**Connection Details** (from portal after configuration):
- **Host**: BMW MQTT broker address
- **Port**: MQTT broker port (typically 8883 for SSL/TLS)
- **Protocol**: MQTT over SSL/TLS
- **Username**: Your GCID (from token response)
- **Password**: Your **id_token** (not access_token!)
- **Topic**: `<gcid>/<vin>` format

**Streaming Configuration:**
1. Subscribe to "CarData Streaming" in portal
2. Click "Configure data stream" button
3. Select which vehicle attributes to stream (e.g., location, battery, tire pressure)
4. Portal displays connection credentials

**Connection Constraints:**
- Only ONE connection per GCID at a time
- If multiple VINs: subscribe to each topic individually on same connection
- When id_token expires: must reconnect with fresh id_token
- Connection closes automatically when id_token expires (1 hour)

**Perl MQTT Example:**
```perl
use Net::MQTT::Simple;
my $mqtt = Net::MQTT::Simple->new("mqtts://bmw_host:8883");
$mqtt->login($gcid, $id_token);  # Username = GCID, Password = ID token
$mqtt->subscribe("$gcid/$vin", sub {
    my ($topic, $message) = @_;
    # Forward to LoxBerry MQTT Gateway
});
```

### Error Codes

Common authentication errors:
- **CU-100**: No token sent
- **CU-101**: Authentication error
- **CU-102**: Token expired
- **CU-103**: Token scope is not CarData
- **CU-104**: Token invalid

### Rate Limits

- **REST API**: 50 requests per day
- **Streaming**: No rate limit (use for frequent data access)

## Actual Plugin Implementation

The plugin consists of four main Perl scripts:

### 1. Web Interface (webfrontend/htmlauth/index.cgi)
- CGI script using LoxBerry::System, LoxBerry::Web, HTML::Template
- Handles configuration (client_id, stream_host, VINs, MQTT prefix)
- Initiates OAuth Device Code Flow via oauth-init.pl
- Polls for tokens via oauth-poll.pl
- Controls bridge daemon (start/stop/restart)
- Displays bridge status and logs

### 2. OAuth Initialization (bin/oauth-init.pl)
- Generates PKCE code_verifier and code_challenge
- Requests device code from BMW `/gcdm/oauth/device/code`
- Saves device_code and pkce data to data/ directory
- Returns user_code and verification_uri for user

### 3. OAuth Polling (bin/oauth-poll.pl)
- Polls BMW `/gcdm/oauth/token` for authorization completion
- Saves access_token, id_token, refresh_token, gcid to data/tokens.json
- Returns success/pending/error status

### 4. Token Manager (bin/token-manager.pl)
- Commands: `check`, `refresh`, `status`
- Checks token expiry (refresh if < 5 minutes remaining)
- Refreshes tokens using refresh_token
- Called by cron/cron.30min every 30 minutes

### 5. MQTT Bridge Daemon (bin/bmw-cardata-bridge.pl)
- Runs as daemon process (--daemon flag)
- Uses AnyEvent::MQTT for BMW CarData connection (MQTTS)
- Uses Net::MQTT::Simple for LoxBerry MQTT Gateway
- Subscribes to BMW topics: `<gcid>/<vin>`
- Forwards messages to LoxBerry with configurable topic prefix
- Monitors tokens.json file every 5 minutes for changes
- Auto-reconnects when new id_token detected (refreshed by cron job)
- Does NOT refresh tokens itself (that's the cron job's responsibility)
- Handles SIGTERM, SIGINT (graceful shutdown), SIGHUP (reload config)
- Creates PID file in data/bridge.pid

### 6. Data Storage Structure
**data/tokens.json:**
```json
{
  "access_token": "...",
  "id_token": "...",
  "refresh_token": "...",
  "gcid": "...",
  "expires_at": 1234567890,
  "refresh_expires_at": 1234567890
}
```

**data/config.json:**
```json
{
  "client_id": "...",
  "stream_host": "...",
  "stream_port": 8883,
  "stream_username": "...",
  "vins": ["VIN1", "VIN2"],
  "mqtt_topic_prefix": "bmw-cardata"
}
```

**data/device_code.json:** (temporary, during OAuth flow)
```json
{
  "device_code": "...",
  "user_code": "...",
  "verification_uri": "...",
  "verification_uri_complete": "...",
  "interval": 5,
  "expires_at": 1234567890
}
```

**data/pkce.json:** (temporary, during OAuth flow)
```json
{
  "code_verifier": "..."
}
```

## LoxBerry Path Placeholders (CRITICAL)

**NEVER use absolute paths in plugin code.** LoxBerry uses placeholders that are automatically replaced during installation:

| Placeholder | Replaced with | Example |
|-------------|--------------|---------|
| `REPLACELBPPLUGINDIR` | Plugin directory name | `bmw-cardata` |
| `REPLACELBPBINDIR` | `/opt/loxberry/bin/plugins/PLUGINNAME` | Plugin executables |
| `REPLACELBPDATADIR` | `/opt/loxberry/data/plugins/PLUGINNAME` | Persistent data |
| `REPLACELBPLOGDIR` | `/opt/loxberry/log/plugins/PLUGINNAME` | Log files |
| `REPLACELBPCONFIGDIR` | `/opt/loxberry/config/plugins/PLUGINNAME` | Config files |
| `REPLACELBPTEMPLDIR` | `/opt/loxberry/templates/plugins/PLUGINNAME` | Templates |
| `REPLACELBPHTMLAUTHDIR` | `/opt/loxberry/webfrontend/htmlauth/plugins/PLUGINNAME` | Web interface |

**In Perl CGI scripts**, use LoxBerry variables instead:
- `$lbpbindir` - Binary directory
- `$lbpdatadir` - Data directory
- `$lbplogdir` - Log directory
- `$lbpconfigdir` - Config directory
- `$lbptemplatedir` - Template directory

**Reference:** https://wiki.loxberry.de/entwickler/plugin_fur_den_loxberry_entwickeln_ab_version_1x/automatisches_ersetzen_der_pluginverzeichnisse_replace

## Development Notes

### Code Structure
- Perl CGI scripts use LoxBerry's templating system (HTML::Template)
- Language strings stored in templates/lang/ (loaded via LoxBerry::Web::readlanguage())
- Web interface uses LoxBerry::Web for headers/footers (lbheader/lbfooter)
- Plugin metadata from LoxBerry::System::plugindata()

### Important Constraints
- **Path Placeholders**: ALWAYS use REPLACE* placeholders or LoxBerry variables, NEVER hardcoded paths
- **MQTT Connection**: Only ONE BMW MQTT connection per GCID allowed
- **Token Timing**: Refresh tokens BEFORE expiry (current: 5 min margin for 1-hour tokens)
- **SSL/TLS**: BMW MQTT requires mqtts:// protocol
- **Cron User**: All cron jobs run as 'loxberry' user, not root
- **Commit Format**: Use conventional commits (feat:, fix:, docs:) for changelog generation
- **Separation of Concerns**: Bridge daemon does NOT refresh tokens - it only detects when cron job has refreshed them and reconnects

### Testing & Debugging
- Test OAuth flow: Run `bin/oauth-init.pl` manually, then `bin/oauth-poll.pl`
- Test token refresh: `bin/token-manager.pl check` or `bin/token-manager.pl refresh --force`
- Test bridge: `bin/bmw-cardata-bridge.pl` (without --daemon for foreground mode)
- Check logs in data directory (tokens.json, config.json, device_code.json)
- Bridge PID file: `data/bridge.pid`
- LoxBerry logs: Use LoxBerry::Log module (LOGSTART, LOGINF, LOGERR, LOGEND)

### MQTT Integration Options
1. **UDP Method** (recommended for simple publishing):
   ```perl
   use LoxBerry::IO;
   my $creds = LoxBerry::IO::mqtt_connectiondetails();
   # Send to UDP port: "topic payload"
   ```

2. **Direct Connection** (for subscribing):
   ```perl
   use Net::MQTT::Simple;
   my $mqtt = Net::MQTT::Simple->new($broker);
   ```
- Before doing any plannings or modifications, always check for changes first. I always change files myself to improve the code.