#!/bin/bash
#
# Creates a ZIP archive containing only files tracked by Git
# This archive can be uploaded to LoxBerry for testing
#

# Get the plugin name from plugin.cfg
PLUGIN_NAME=$(grep "^FOLDER=" plugin.cfg | cut -d'=' -f2)
if [ -z "$PLUGIN_NAME" ]; then
    PLUGIN_NAME="bmw-cardata"
fi

# Get version from plugin.cfg
VERSION=$(grep "^VERSION=" plugin.cfg | cut -d'=' -f2)
if [ -z "$VERSION" ]; then
    VERSION="dev"
fi

# Add snapshot suffix to version
VERSION="${VERSION}-snapshot"

# Determine archive format based on available tools
if command -v zip &> /dev/null; then
    ARCHIVE_NAME="${PLUGIN_NAME}-${VERSION}.zip"
    ARCHIVE_TYPE="zip"
else
    # Fallback to tar.gz if zip is not available
    ARCHIVE_NAME="${PLUGIN_NAME}-${VERSION}.tar.gz"
    ARCHIVE_TYPE="tar.gz"
fi

echo "Creating plugin archive: ${ARCHIVE_NAME}"
echo "Plugin: ${PLUGIN_NAME}"
echo "Version: ${VERSION}"
echo "Format: ${ARCHIVE_TYPE}"
echo ""
echo "NOTE: This creates a snapshot of the current working directory,"
echo "including uncommitted changes."
echo ""

# Create temporary directory
TEMP_DIR=$(mktemp -d)
PLUGIN_DIR="${TEMP_DIR}/${PLUGIN_NAME}"

# Create plugin directory structure
mkdir -p "${PLUGIN_DIR}"

echo "Copying current working directory files..."

# Copy all files except excluded directories
# Using find and cp since rsync may not be available on all systems
find . -type f \
    ! -path "./.git/*" \
    ! -path "./.github/*" \
    ! -path "./.idea/*" \
    ! -path "./.claude/*" \
    ! -path "./node_modules/*" \
    ! -path "./dev/*" \
    ! -name "*.zip" \
    ! -name "*.tar.gz" \
    ! -name "package.json" \
    ! -name "package-lock.json" \
    ! -name "create-plugin-zip.cmd" \
    ! -name "create-plugin-zip.sh" \
    ! -name "create-plugin-zip.ps1" \
    ! -name "create-plugin-zip.exclude" \
    ! -name "CLAUDE.md" \
    ! -name ".gitignore" \
    -exec bash -c 'mkdir -p "'"${PLUGIN_DIR}"'/$(dirname "{}")" && cp "{}" "'"${PLUGIN_DIR}"'/{}"' \;

# Create the ZIP archive from the temporary directory
cd "${TEMP_DIR}"

# Create archive based on detected type
if [ "${ARCHIVE_TYPE}" = "zip" ]; then
    # Use zip command (Linux/macOS)
    zip -r "${ARCHIVE_NAME}" "${PLUGIN_NAME}" > /dev/null
else
    # Use tar.gz as fallback (Git Bash on Windows)
    tar -czf "${ARCHIVE_NAME}" "${PLUGIN_NAME}"
fi

# Move archive to original directory
if [ -f "${ARCHIVE_NAME}" ]; then
    mv "${ARCHIVE_NAME}" "${OLDPWD}/"
else
    echo "Error: Failed to create archive"
    cd "${OLDPWD}"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Cleanup
cd "${OLDPWD}"
rm -rf "${TEMP_DIR}"

echo ""
echo "✓ Successfully created: ${ARCHIVE_NAME}"
echo ""
if [ -f "${ARCHIVE_NAME}" ]; then
    echo "File size: $(du -h "${ARCHIVE_NAME}" | cut -f1)"
fi
echo ""
echo "You can now upload this file to LoxBerry for testing."
if [ "${ARCHIVE_TYPE}" = "tar.gz" ]; then
    echo ""
    echo "Note: LoxBerry plugin manager may require ZIP format."
    echo "Consider installing zip utility or use Windows PowerShell/CMD script instead."
fi
