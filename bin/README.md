# BMW CarData OAuth Scripts

## Initial Setup

### Prerequisites

1. Create a Client ID in the BMW CarData Customer Portal:
   - Visit https://bmw-cardata.bmwgroup.com/customer
   - Click "Create CarData Client"
   - Copy the generated Client ID

2. Subscribe to services in the portal:
   - Subscribe to "CarData API"
   - Subscribe to "CarData Streaming"

### Installation

1. Edit `oauth-init.pl`, `oauth-poll.pl`, and `token-manager.pl`:
   ```perl
   use constant {
       CLIENT_ID => 'YOUR_CLIENT_ID_HERE',  # Replace with your actual Client ID
       ...
   };
   ```

2. Make scripts executable:
   ```bash
   chmod +x oauth-init.pl oauth-poll.pl token-manager.pl
   ```

## Usage

### Step 1: Initialize OAuth Flow

Run the initialization script:
```bash
./oauth-init.pl
```

This will:
- Generate PKCE code_verifier and code_challenge (RFC 7636)
- Request a device code from BMW CarData API
- Open your browser to the verification URL
- Save temporary data to `../data/pkce.json` and `../data/device_code.json`

### Step 2: Complete Browser Authorization

1. Log in with your BMW ID credentials
2. Approve the authorization request
3. The browser will show a confirmation

### Step 3: Retrieve Tokens

Run the polling script:
```bash
./oauth-poll.pl
```

This will:
- Poll the BMW CarData API for tokens
- Wait for user authorization (if not completed yet)
- Save tokens to `../data/tokens.json`
- Clean up temporary files

## Token Information

The `tokens.json` file contains:

- **access_token**: For REST API calls (valid 1 hour)
- **id_token**: For MQTT streaming (valid 1 hour)
- **refresh_token**: For refreshing tokens (valid 2 weeks)
- **gcid**: Your unique user identifier
- **expires_at**: Unix timestamp when tokens expire
- **refresh_expires_at**: Unix timestamp when refresh token expires

## Troubleshooting

### Error: "PKCE data not found"
Run `oauth-init.pl` first before running `oauth-poll.pl`.

### Error: "Device code has expired"
The device code is only valid for a limited time (usually 5-15 minutes). Run `oauth-init.pl` again.

### Error: "Authorization was denied"
You rejected the authorization in the browser. Run `oauth-init.pl` again if you want to authorize.

### Browser doesn't open automatically
Copy the verification URL from the console output and open it manually in your browser.

## Security Notes

- Never commit `tokens.json` to version control
- The `data/` directory should be writable by the loxberry user
- Tokens are sensitive - protect the `data/` directory with appropriate permissions
- The CLIENT_ID should be treated as confidential

## Token Management

### Automatic Token Refresh (Cron Job)

The plugin automatically refreshes tokens every 30 minutes via cron job.

The cron job runs:
```
*/30 * * * * loxberry /opt/loxberry/bin/plugins/loxberry-bmw-cardata/token-manager.pl check
```

Logs are written to: `/opt/loxberry/log/plugins/loxberry-bmw-cardata/token-refresh.log`

### Manual Token Management

#### Check Token Status
```bash
./token-manager.pl status
```

Shows:
- Current token validity
- Time until expiry
- Refresh token status
- User GCID and scopes

#### Check and Refresh if Needed
```bash
./token-manager.pl check
```

Automatically refreshes tokens if they expire within 5 minutes.

#### Force Refresh
```bash
./token-manager.pl refresh --force
```

Forces immediate token refresh regardless of expiry time.

#### Verbose Output
```bash
./token-manager.pl refresh --verbose
```

Shows detailed API responses and timing information.

### Token Lifecycle

1. **Initial tokens** (via oauth-init.pl + oauth-poll.pl):
   - Valid for 1 hour
   - Refresh token valid for 2 weeks

2. **Automatic refresh** (via cron every 30 min):
   - Checks if tokens expire within 5 minutes
   - Refreshes access_token and id_token
   - Gets new refresh_token (resets 2-week timer)

3. **Re-authentication required** when:
   - Refresh token expires (after 2 weeks without refresh)
   - Client ID is unsubscribed from services
   - Manual token revocation

## MQTT Bridge Daemon

The bridge daemon connects to BMW CarData MQTT and forwards messages to LoxBerry MQTT Gateway.

### Configuration

1. Create `../data/config.json` (or use web interface):
   ```json
   {
     "stream_host": "your-mqtt-host.bmwgroup.com",
     "stream_port": 8883,
     "vins": ["WBADEXXXXXXX12345"],
     "mqtt_topic_prefix": "bmw"
   }
   ```

2. Get stream_host and stream_port from BMW CarData Customer Portal:
   - Subscribe to "CarData Streaming"
   - Click "Configure data stream"
   - Select vehicle attributes
   - Copy connection credentials

### Running the Bridge

#### Using Control Script (Recommended)

```bash
# Start daemon
./bridge-control.sh start

# Stop daemon
./bridge-control.sh stop

# Restart daemon
./bridge-control.sh restart

# Reload configuration (without restart)
./bridge-control.sh reload

# Check status
./bridge-control.sh status

# Follow logs
./bridge-control.sh logs
```

#### Manual Execution

```bash
# Run in foreground (verbose)
./bmw-cardata-bridge.pl --verbose

# Run as daemon
./bmw-cardata-bridge.pl --daemon

# Debug mode
./bmw-cardata-bridge.pl --debug
```

### How it Works

1. **Connects to BMW MQTT** using id_token (password) and gcid (username)
2. **Subscribes to topics** for configured VINs (`<gcid>/<vin>`)
3. **Forwards messages** to LoxBerry MQTT Gateway via UDP
4. **Transforms topics** to include prefix (default: `bmw/<gcid>/<vin>`)
5. **Auto-reconnects** when id_token expires (every ~50 minutes)
6. **Triggers token refresh** when tokens expire within 10 minutes

### Message Flow

```
BMW CarData MQTT → Bridge → LoxBerry MQTT Gateway → Loxone Miniserver
```

Example:
- BMW topic: `gc12345/WBA12345/location`
- LoxBerry topic: `bmw/gc12345/WBA12345/location`
- Message: `{"latitude": 48.1351, "longitude": 11.5820}`

### Logs

Daemon logs are written to:
- `/opt/loxberry/log/plugins/loxberry-bmw-cardata/bridge.log`

### Troubleshooting

**Bridge won't start:**
- Check tokens exist: `ls -la ../data/tokens.json`
- Check config exists: `ls -la ../data/config.json`
- Check logs: `tail -f /opt/loxberry/log/plugins/loxberry-bmw-cardata/bridge.log`

**No messages received:**
- Verify VIN is correct in config
- Check BMW portal: Stream configuration active?
- Check LoxBerry MQTT Gateway is running
- Enable debug mode: `./bmw-cardata-bridge.pl --debug`

**Connection drops:**
- Normal after ~1 hour (token expiry) - should auto-reconnect
- Check token-manager cron is running: `crontab -l`

## Next Steps

After successful token retrieval:
1. Configure your VIN and stream settings in `../data/config.json` (or web interface)
2. Start the bridge daemon: `./bridge-control.sh start`
3. Monitor logs: `./bridge-control.sh logs`
4. The token refresh will be handled automatically by cron job
