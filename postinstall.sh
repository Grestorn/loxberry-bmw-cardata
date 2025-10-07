#!/bin/bash

# Shell script which is executed by bash *AFTER* complete installation is done
# (but *BEFORE* postupdate). Use with caution and remember, that all systems may
# be different!
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

# Install required Perl modules via CPAN
echo "<INFO> Installing required Perl modules..."

# Set CPAN environment for non-interactive installation
export PERL_MM_USE_DEFAULT=1
export PERL_AUTOINSTALL="--defaultdeps"

# Create local lib directory for plugin-specific modules in LBPBIN
PERL5LIB_DIR="$PBIN/perl5"
mkdir -p "$PERL5LIB_DIR"

echo "<INFO> Installing AnyEvent::MQTT and dependencies..."
echo "<INFO> Using cpanm for installation (skipping tests, docs, and man pages)..."

# Install with minimal footprint:
# -L = local-lib location
# --notest = skip running tests (faster, smaller)
# --no-man-pages = skip installing man pages (saves space)
# --quiet = reduce output noise
cpanm -L "$PERL5LIB_DIR" --notest --no-man-pages --quiet AnyEvent::MQTT
INSTALL_RESULT=$?

# Check installation result
if [ $INSTALL_RESULT -eq 0 ]; then
    echo "<OK> Perl modules installed successfully!"

    # Optional: Clean up unnecessary files to save space
    echo "<INFO> Cleaning up build files..."
    rm -rf "$PERL5LIB_DIR/man" 2>/dev/null
    rm -rf "$PERL5LIB_DIR/.meta" 2>/dev/null
    find "$PERL5LIB_DIR" -name "*.pod" -type f -delete 2>/dev/null
    find "$PERL5LIB_DIR" -name "perllocal.pod" -type f -delete 2>/dev/null
    echo "<OK> Cleanup complete."
else
    echo "<WARNING> Perl module installation completed with warnings. Plugin may still work."
fi

echo "<INFO> Perl module installation complete."

# Exit with Status 0
exit 0