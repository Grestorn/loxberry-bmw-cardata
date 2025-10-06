# Config Directory

This directory is designated for plugin configuration files that persist across upgrades.

## Purpose

The `config/` directory is part of LoxBerry's plugin architecture and is mapped to:
```
/opt/loxberry/config/plugins/loxberry-bmw-cardata/
```

## Current Status

Currently **not used** by this plugin.

## Why Not Used?

This plugin stores its configuration in the `data/` directory instead:
- **data/config.json** - Plugin configuration (Client ID, VINs, MQTT settings)
- **data/tokens.json** - OAuth tokens
- **data/device_code.json** - Temporary OAuth device code data
- **data/bridge.pid** - Bridge daemon process ID

## When to Use config/ vs data/

### Use `config/` for:
- User-editable configuration files
- Settings that should be manually modifiable
- Configuration templates
- Files that administrators might want to backup separately

### Use `data/` for:
- Runtime data (PID files, temporary files)
- OAuth tokens and secrets
- Auto-generated configuration
- Files that should not be manually edited

## LoxBerry Behavior

Both directories:
- ✅ Persist across plugin upgrades
- ✅ Are excluded from plugin ZIP archives
- ✅ Owned by user `loxberry`
- ✅ Have permissions 755 (directories) / 644 (files)

The difference is semantic - `config/` suggests "configuration to be managed by admin", while `data/` suggests "data managed by plugin".

## Future Use

This directory is kept for potential future use if the plugin needs to store:
- Configuration templates
- Backup configuration files
- User-editable settings files

## .gitkeep

The `.gitkeep` file ensures this empty directory is tracked in Git. It can be removed once actual configuration files are added.

## See Also

- `../data/README.md` - Where plugin configuration is currently stored
- `../webfrontend/htmlauth/index.cgi` - Web interface that manages configuration
