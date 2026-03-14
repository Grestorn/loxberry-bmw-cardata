#!/bin/bash

# Shell script which is executed in case of an update (if this plugin is already
# installed on the system). This script is after main installation is done  (*AFTER*
# postinstall.sh) and can be used e.g. to save existing configfiles to /tmp
# during installation. Use with caution and remember, that all systems may be
# different!
#
# Exit code must be 0 if executed successfull.
# Exit code 1 gives a warning but continues installation.
# Exit code 2 cancels installation.
#
# Will be executed as user "loxberry".
#
# You can use all vars from /etc/environment in this script.
#
# We add 5 additional arguments when executing this script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>
#
# For logging, print to STDOUT. You can use the following tags for showing
# different colorized information during plugin installation:
#
# <OK> This was ok!"
# <INFO> This is just for your information."
# <WARNING> This is a warning!"
# <ERROR> This is an error!"
# <FAIL> This is a fail!"

# To use important variables from command line use the following code:
COMMAND=$0    # Zero argument is shell command
PTEMPDIR=$1   # First argument is temp folder during install
PSHNAME=$2    # Second argument is Plugin-Name for scipts etc.
PDIR=$3       # Third argument is Plugin installation folder
PVERSION=$4   # Forth argument is Plugin version
#LBHOMEDIR=$5 # Comes from /etc/environment now. Fifth argument is
              # Base folder of LoxBerry
PTEMPPATH=$6  # Sixth argument is full temp path during install (see also $1)

# Combine them with /etc/environment
PHTMLAUTH=$LBHOMEDIR/webfrontend/htmlauth/plugins/$PDIR
PHTML=$LBPHTML/$PDIR
PTEMPL=$LBPTEMPL/$PDIR
PDATA=$LBPDATA/$PDIR
PLOGS=$LBPLOG/$PDIR # Note! This is stored on a Ramdisk now!
PCONFIG=$LBPCONFIG/$PDIR
PSBIN=$LBPSBIN/$PDIR
PBIN=$LBPBIN/$PDIR

echo "<INFO> Copy back existing backup"
cp -p -v -r $PTEMPPATH/upgrade/config/* $PCONFIG
cp -p -v -r $PTEMPPATH/upgrade/data/* $PDATA
cp -p -v -r $PTEMPPATH/upgrade/logs/* $PLOGS

echo "<INFO> Remove temporary folders"
rm -r $PTEMPPATH/upgrade

# --- Migration: single-account (flat) -> multi-account layout ---
# Detect flat format: tokens.json or config.json directly in data root (not in accounts/)
# Note: postinstall.sh may have already created an empty accounts/ directory,
# so we check for root-level files regardless of whether accounts/ exists.
if [ -f "$PDATA/tokens.json" ] || [ -f "$PDATA/config.json" ]; then
    echo "<INFO> BMW CarData: Migrating from single-account to multi-account layout..."
    mkdir -p "$PDATA/accounts/default"

    # Move per-account files to accounts/default/
    for FILE in config.json tokens.json device_code.json pkce.json; do
        if [ -f "$PDATA/$FILE" ]; then
            mv "$PDATA/$FILE" "$PDATA/accounts/default/$FILE"
            echo "<INFO> BMW CarData: Moved $FILE -> accounts/default/$FILE"
        fi
    done

    # Move bridge state file too
    if [ -f "$PDATA/_bridge_was_running" ]; then
        mv "$PDATA/_bridge_was_running" "$PDATA/accounts/default/_bridge_was_running"
    fi

    echo "<OK> BMW CarData: Migration to multi-account layout complete"
fi

# Ensure accounts directory exists
mkdir -p "$PDATA/accounts"

# Restart bridges that were running before upgrade
echo "<INFO> BMW CarData: Checking which bridges should be restarted..."

for ACCT_DIR in "$PDATA"/accounts/*/; do
    if [ -d "$ACCT_DIR" ] && [ -f "$ACCT_DIR/_bridge_was_running" ]; then
        ACCT_ID=$(basename "$ACCT_DIR")
        echo "<INFO> BMW CarData: Bridge [$ACCT_ID] was running before upgrade, restarting..."

        if [ -x "$PBIN/bridge-control.sh" ]; then
            "$PBIN/bridge-control.sh" --account "$ACCT_ID" start
            if [ $? -eq 0 ]; then
                echo "<OK> BMW CarData: Bridge [$ACCT_ID] restarted successfully"
            else
                echo "<WARNING> BMW CarData: Failed to restart bridge [$ACCT_ID]"
            fi
        else
            echo "<WARNING> BMW CarData: bridge-control.sh not found or not executable"
        fi

        rm -f "$ACCT_DIR/_bridge_was_running"
    fi
done

echo "<OK> BMW CarData: Post-upgrade completed"

exit 0