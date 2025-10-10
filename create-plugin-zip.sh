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

# Output filename
ZIP_NAME="${PLUGIN_NAME}-${VERSION}.zip"

echo "Creating plugin ZIP archive: ${ZIP_NAME}"
echo "Plugin: ${PLUGIN_NAME}"
echo "Version: ${VERSION}"
echo ""

# Create temporary directory
TEMP_DIR=$(mktemp -d)
PLUGIN_DIR="${TEMP_DIR}/${PLUGIN_NAME}"

# Create plugin directory structure
mkdir -p "${PLUGIN_DIR}"

echo "Copying Git-tracked files..."

# Use git archive to export all tracked files to the temporary directory
git archive HEAD | tar -x -C "${PLUGIN_DIR}"

# Create the ZIP archive from the temporary directory
cd "${TEMP_DIR}"
zip -r "${ZIP_NAME}" "${PLUGIN_NAME}" > /dev/null

# Move ZIP to original directory
mv "${ZIP_NAME}" "${OLDPWD}/"

# Cleanup
cd "${OLDPWD}"
rm -rf "${TEMP_DIR}"

echo ""
echo "✓ Successfully created: ${ZIP_NAME}"
echo ""
echo "File size: $(du -h "${ZIP_NAME}" | cut -f1)"
echo ""
echo "You can now upload this file to LoxBerry for testing."
