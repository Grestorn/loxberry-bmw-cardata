#!/bin/bash

# Shell script which is executed in case of an update (if this plugin is already
# installed on the system). This script is executed as very first step (*BEFORE*
# preinstall.sh) and can be used e.g. to save existing configfiles to /tmp
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
PCGI=$LBPCGI/$PDIR
PHTML=$LBPHTML/$PDIR
PTEMPL=$LBPTEMPL/$PDIR
PDATA=$LBPDATA/$PDIR
PLOGS=$LBPLOG/$PDIR # Note! This is stored on a Ramdisk now!
PCONFIG=$LBPCONFIG/$PDIR
PSBIN=$LBPSBIN/$PDIR
PBIN=$LBPBIN/$PDIR

# Stop BMW CarData bridge if running and save state BEFORE backup
echo "<INFO> BMW CarData: Checking if bridge is running..."

BRIDGE_WAS_RUNNING=0
if [ -f "$PDATA/bridge.pid" ]; then
    PID=$(cat "$PDATA/bridge.pid")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "<INFO> BMW CarData: Bridge is currently running (PID $PID)"
        BRIDGE_WAS_RUNNING=1

        # Save state for postupgrade BEFORE backup
        echo "1" > "$PDATA/.bridge_was_running"

        # Stop the bridge
        echo "<INFO> BMW CarData: Stopping MQTT bridge daemon..."
        kill -TERM "$PID"

        # Wait for graceful shutdown
        COUNTER=0
        while ps -p "$PID" > /dev/null 2>&1 && [ $COUNTER -lt 10 ]; do
            sleep 1
            COUNTER=$((COUNTER + 1))
        done

        # Force kill if still running
        if ps -p "$PID" > /dev/null 2>&1; then
            echo "<WARNING> BMW CarData: Force stopping daemon..."
            kill -KILL "$PID"
        fi

        echo "<OK> BMW CarData: Daemon stopped"
    else
        echo "<INFO> BMW CarData: Bridge PID file exists but process not running"
    fi
    rm -f "$PDATA/bridge.pid"
else
    echo "<INFO> BMW CarData: Bridge is not running"
    # Make sure state file doesn't exist
    rm -f "$PDATA/.bridge_was_running"
fi

echo "<INFO> Creating temporary folders for upgrading"
mkdir -p $PTEMPPATH/upgrade
mkdir -p $PTEMPPATH/upgrade/config
mkdir -p $PTEMPPATH/upgrade/data
mkdir -p $PTEMPPATH/upgrade/logs

echo "<INFO> Backing up existing config files"
cp -p -v -r $PCONFIG/* $PTEMPPATH/upgrade/config
cp -p -v -r $PDATA/* $PTEMPPATH/upgrade/data
cp -p -v -r $PLOGS/* $PTEMPPATH/upgrade/logs

echo "<OK> BMW CarData: Pre-upgrade completed"

exit 0