# IntelliJ Run Configurations

This directory contains shared IntelliJ IDEA run configurations for the project.

## Available Configurations

### Release Folder

**Official Release Scripts (npm):**
- `npm: release:major` - Create major release (x.0.0)
- `npm: release:minor` - Create minor release (0.x.0)
- `npm: release:patch` - Create patch release (0.0.x)

**Prerelease Scripts (npm):**
- `npm: pre:major` - Create major prerelease (x.0.0-rc.N)
- `npm: pre:minor` - Create minor prerelease (0.x.0-rc.N)
- `npm: pre:patch` - Create patch prerelease (0.0.x-rc.N)

### Build Folder

**Plugin Snapshot Creation:**
- `Create Plugin Snapshot (CMD)` - Windows Batch script (creates .zip)
- `Create Plugin Snapshot (Bash)` - Bash script for Git Bash/Linux/macOS (creates .zip or .tar.gz)
- `Create Plugin Snapshot (PowerShell)` - PowerShell script (creates .zip)

All snapshot scripts create a `-snapshot` suffixed version containing the current working directory (including uncommitted changes).

## Usage

These configurations will automatically appear in IntelliJ IDEA's Run/Debug configurations dropdown when you open the project.

## Notes

- Release scripts require Node.js and npm dependencies installed (`npm install`)
- Snapshot scripts create archives ready for testing in LoxBerry
- All configurations use `$PROJECT_DIR$` variable for portability
