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

# Restart bridge if it was running before upgrade
echo "<INFO> BMW CarData: Checking if bridge should be restarted..."

if [ -f "$PDATA/.bridge_was_running" ]; then
    echo "<INFO> BMW CarData: Bridge was running before upgrade, restarting..."

    # Start bridge via bridge-control.sh
    if [ -x "$PBIN/bridge-control.sh" ]; then
        "$PBIN/bridge-control.sh" start
        if [ $? -eq 0 ]; then
            echo "<OK> BMW CarData: Bridge restarted successfully"
        else
            echo "<WARNING> BMW CarData: Failed to restart bridge"
        fi
    else
        echo "<WARNING> BMW CarData: bridge-control.sh not found or not executable"
    fi

    # Remove state file
    rm -f "$PDATA/.bridge_was_running"
else
    echo "<INFO> BMW CarData: Bridge was not running before upgrade, not starting"
fi

echo "<OK> BMW CarData: Post-upgrade completed"

exit 0