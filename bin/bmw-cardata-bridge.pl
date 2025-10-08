#!/usr/bin/perl

# Add local Perl module path
use lib "REPLACELBPBINDIR/perl5/lib/perl5";

use strict;
use warnings;
use AnyEvent;
use AnyEvent::MQTT;
use IO::Socket::SSL qw(SSL_VERIFY_PEER);
use LWP::UserAgent;
use JSON;
use Net::MQTT::Simple;
use Time::HiRes qw(sleep time);
use File::Basename;
use POSIX qw(strftime);
use Getopt::Long;
use LoxBerry::System;
use LoxBerry::IO;
use LoxBerry::Log;

# Configuration
use constant {
    BMW_MQTT_PROTOCOL => 'mqtts',     # MQTT over SSL/TLS
    RECONNECT_DELAY => 900,            # Seconds to wait before reconnect (15 minutes)
    TOKEN_CHECK_INTERVAL => 300,       # Check token expiry every 5 minutes
    TOKEN_REFRESH_MARGIN => 600,       # Refresh when < 10 minutes left
};

# Plugin directories
my $bin_dir = "REPLACELBPBINDIR";
my $data_dir = "REPLACELBPDATADIR";
my $log_dir = "REPLACELBPLOGDIR";
my $tokens_file = "$data_dir/tokens.json";
my $config_file = "$data_dir/config.json";

# Note: CLIENT_ID is read from config file and not needed by bridge (only for OAuth operations)

# Command line options
my $daemon = 0;

GetOptions(
    'daemon|d' => \$daemon,
) or die "Usage: $0 [--daemon]\n";

# Global state
my $running = 1;
my $bmw_mqtt;
my $mqtt_cv;  # AnyEvent condvar for MQTT connection
my $loxberry_mqtt;  # Net::MQTT::Simple connection to LoxBerry
my $current_tokens;
my $current_config;
my $last_token_check = 0;
my $connection_active = 0;

# Initialize logging
my $log = LoxBerry::Log->new(
    name => 'bmw-cardata-bridge',
    stderr => 1,  # Redirect STDERR to log
    addtime => 1  # Add timestamps to log entries
);

# Signal handlers for graceful shutdown
$SIG{TERM} = sub {
    LOGINF("Received SIGTERM, shutting down...");
    $running = 0;
    $mqtt_cv->send if $mqtt_cv;  # Exit event loop
};
$SIG{INT} = sub {
    LOGINF("Received SIGINT, shutting down...");
    $running = 0;
    $mqtt_cv->send if $mqtt_cv;  # Exit event loop
};
$SIG{HUP} = sub {
    LOGINF("Received SIGHUP, reloading configuration...");
    reload_config();
};

# Main
LOGSTART("BMW CarData Bridge");
LOGINF("=== BMW CarData MQTT Bridge Starting ===");
LOGDEB("Daemon mode: " . ($daemon ? "yes" : "no"));

# Daemonize if requested
if ($daemon) {
    daemonize();
}

# Load configuration and tokens
unless (load_configuration()) {
    LOGCRIT("Failed to load configuration. Please configure plugin first.");
    LOGEND;
    die "Failed to load configuration.\n";
}

# Connect to LoxBerry MQTT Gateway (one-time setup)
unless (setup_loxberry_connection()) {
    LOGCRIT("Failed to setup LoxBerry connection.");
    LOGEND;
    die "Failed to setup LoxBerry connection.\n";
}

# Main reconnection loop
while ($running) {
    LOGINF("=== Starting connection cycle ===");

    # Check if tokens need refresh
    check_and_refresh_tokens();

    # Check if tokens are still valid
    if (token_expired()) {
        LOGERR("Token expired and refresh failed. Waiting before retry...");
        sleep(RECONNECT_DELAY);
        next;
    }

    # Connect to BMW CarData MQTT
    unless (connect_to_bmw_mqtt()) {
        LOGERR("Failed to connect to BMW MQTT. Waiting " . RECONNECT_DELAY . " seconds before retry...");
        sleep(RECONNECT_DELAY);
        next;
    }

    $connection_active = 1;
    LOGOK("Bridge is active and forwarding messages");

    # Set up periodic token check timer (every 5 minutes)
    my $token_check_timer = AnyEvent->timer(
        after => TOKEN_CHECK_INTERVAL,
        interval => TOKEN_CHECK_INTERVAL,
        cb => sub {
            LOGDEB("Periodic token check...");
            check_and_refresh_tokens();

            # Check if token was refreshed - if so, trigger reconnect
            if (token_expired()) {
                LOGWARN("Token expired despite refresh, triggering reconnect...");
                $connection_active = 0;
                $mqtt_cv->send if $mqtt_cv;
            }
        }
    );

    # Create AnyEvent condvar for event loop
    $mqtt_cv = AnyEvent->condvar;

    # Run the event loop (this blocks until $mqtt_cv->send is called or error occurs)
    LOGINF("Starting AnyEvent event loop...");

    # Wrap event loop in eval to catch all errors
    my $loop_error;
    eval {
        $mqtt_cv->recv;
    };
    $loop_error = $@;

    # Cleanup current connection
    cleanup_connections();

    # Check for errors from event loop
    if ($loop_error) {
        LOGERR("Event loop error: $loop_error");
    }

    # Check if we should continue running
    unless ($running) {
        LOGINF("Shutdown requested, exiting...");
        last;
    }

    # Wait before reconnecting
    LOGINF("Connection lost. Waiting " . RECONNECT_DELAY . " seconds before reconnecting...");
    sleep(RECONNECT_DELAY);
}

# Final cleanup
LOGINF("=== BMW CarData MQTT Bridge Stopped ===");
LOGEND;
exit 0;

#
# Configuration Management
#

sub load_configuration {
    LOGDEB("Loading configuration...");

    # Load tokens
    unless (-f $tokens_file) {
        LOGERR("Tokens file not found: $tokens_file");
        LOGERR("Please run oauth-init.pl and oauth-poll.pl first");
        return 0;
    }

    $current_tokens = eval { load_json($tokens_file) };
    if ($@) {
        LOGERR("Failed to parse tokens file: $@");
        return 0;
    }

    unless (exists $current_tokens->{id_token}) {
        LOGERR("Invalid tokens file: missing id_token");
        return 0;
    }

    # Load config
    unless (-f $config_file) {
        LOGWARN("Config file not found: $config_file");
        LOGWARN("Using default configuration");
        $current_config = get_default_config();
    } else {
        $current_config = eval { load_json($config_file) };
        if ($@) {
            LOGERR("Failed to parse config file: $@");
            return 0;
        }
    }

    # Validate required config
    unless (exists $current_config->{stream_host} && exists $current_config->{stream_port} && exists $current_config->{stream_username}) {
        LOGERR("Invalid config: missing stream_host, stream_port, or stream_username");
        LOGERR("Please configure the plugin via web interface");
        return 0;
    }

    LOGOK("Configuration loaded successfully");
    LOGDEB("Stream username: $current_config->{stream_username}");
    LOGDEB("Stream host: $current_config->{stream_host}:$current_config->{stream_port}");

    return 1;
}

sub reload_config {
    LOGINF("Reloading configuration...");
    $connection_active = 0;  # Trigger reconnect
}

sub get_default_config {
    return {
        stream_host => '',
        stream_port => 8883,
        stream_username => '',
        vins => [],
        mqtt_topic_prefix => 'bmw',
    };
}

#
# Token Management
#

sub check_and_refresh_tokens {
    $last_token_check = time();

    return unless -f $tokens_file;

    # Reload tokens from file (cron job updates this file)
    my $tokens;
    eval {
        $tokens = load_json($tokens_file);
    };
    if ($@) {
        LOGERR("Failed to load tokens file: $@");
        return;
    }
    return unless $tokens;

    # Check if tokens have been refreshed (by comparing id_token)
    my $old_id_token = $current_tokens->{id_token} || '';
    my $new_id_token = $tokens->{id_token} || '';

    if ($old_id_token ne $new_id_token && $new_id_token ne '') {
        LOGOK("New id_token detected - cron job has refreshed tokens");
        $current_tokens = $tokens;

        # Trigger reconnection to use new id_token
        LOGINF("Triggering reconnect to use new id_token...");
        $connection_active = 0;
        # Exit event loop to trigger reconnection in main loop
        $mqtt_cv->send if $mqtt_cv;
        return;
    }

    # Log token status
    my $now = time();
    my $expires_at = $tokens->{expires_at} || 0;
    my $time_left = $expires_at - $now;

    if ($time_left < TOKEN_REFRESH_MARGIN) {
        LOGWARN("Token expires soon (${time_left}s left) - waiting for cron job to refresh");
    } elsif ($time_left < 0) {
        LOGERR("Token has expired (${time_left}s ago) - waiting for cron job to refresh");
    } else {
        LOGDEB("Token valid for " . int($time_left / 60) . " minutes");
    }
}

sub token_expired {
    return 0 unless $current_tokens;
    my $now = time();
    my $expires_at = $current_tokens->{expires_at} || 0;
    return $expires_at < $now;
}

#
# LoxBerry MQTT Gateway Connection (Net::MQTT::Simple)
#

sub setup_loxberry_connection {
    LOGINF("Setting up LoxBerry MQTT Gateway connection...");

    # Get MQTT connection details from LoxBerry
    my $mqtt_creds;
    eval {
        $mqtt_creds = LoxBerry::IO::mqtt_connectiondetails();
    };

    if ($@ || !$mqtt_creds) {
        LOGERR("Failed to get MQTT connection details: $@");
        return 0;
    }

    my $broker_host = $mqtt_creds->{brokerhost} || 'localhost';
    my $broker_port = $mqtt_creds->{brokerport} || 1883;
    my $broker_user = $mqtt_creds->{brokeruser};
    my $broker_pass = $mqtt_creds->{brokerpass};

    LOGINF("Connecting to LoxBerry MQTT Gateway at $broker_host:$broker_port");

    # Allow insecure login if no TLS
    $ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;

    # Connect to LoxBerry MQTT Gateway
    eval {
        $loxberry_mqtt = Net::MQTT::Simple->new("$broker_host:$broker_port");

        # Login if credentials provided
        if ($broker_user && $broker_pass) {
            LOGDEB("Authenticating with username: $broker_user");
            $loxberry_mqtt->login($broker_user, $broker_pass);
        }
    };

    if ($@) {
        LOGERR("Failed to connect to LoxBerry MQTT: $@");
        return 0;
    }

    LOGOK("LoxBerry MQTT Gateway connection established");
    return 1;
}

#
# BMW CarData MQTT Connection
#

sub connect_to_bmw_mqtt {
    LOGINF("Connecting to BMW CarData MQTT...");

    my $host = $current_config->{stream_host};
    my $port = $current_config->{stream_port};
    my $stream_username = $current_config->{stream_username};
    my $id_token = $current_tokens->{id_token};

    unless ($host && $port && $stream_username) {
        LOGERR("Missing BMW MQTT host, port, or stream_username in configuration");
        return 0;
    }

    unless ($id_token) {
        LOGERR("Missing ID token - cannot authenticate to BMW MQTT");
        return 0;
    }

    LOGINF("Connecting to mqtts://$host:$port");
    LOGINF("MQTT Username: $stream_username");
    LOGINF("ID Token (first 50 chars): " . substr($id_token, 0, 50) . "...");
    LOGINF("ID Token (last 50 chars): ..." . substr($id_token, -50));
    LOGDEB("Full ID Token: $id_token");

    # Wrap all MQTT operations in eval to catch errors
    eval {
        # Create MQTT connection with all required BMW parameters
        LOGINF("Creating MQTT connection with TLS, keepalive=30, clean_session=1...");

        $bmw_mqtt = AnyEvent::MQTT->new(
            host => $host,
            port => $port,
            user_name => $stream_username,
            password => $id_token,
            keep_alive_timer => 30,      # BMW expects 30 seconds keepalive
            clean_session => 1,           # Clean session flag
            timeout => 30,                # 30 second connection timeout
            # TLS/SSL - use 'tls' parameter (not 'ssl')
            tls => 1,
            on_error => sub {
                my ($fatal, $message) = @_;
                if ($fatal) {
                    LOGCRIT("FATAL MQTT error: $message");
                    $connection_active = 0;
                    # Exit event loop on fatal error
                    $mqtt_cv->send if $mqtt_cv;
                } else {
                    LOGWARN("MQTT warning: $message");
                }
            },
        );

        LOGOK("MQTT connection object created successfully");
        LOGINF("Connection will be established asynchronously when event loop starts...");

        # Subscribe to topics for each VIN
        my @vins = @{$current_config->{vins} || []};

        if (@vins == 0) {
            LOGWARN("No VINs configured, subscribing to all user topics");
            my $topic = "$stream_username/#";
            LOGINF("Subscribing to topic: $topic");

            eval {
                $bmw_mqtt->subscribe(
                    topic => $topic,
                    qos => 0,
                    callback => sub {
                        my ($topic, $message) = @_;
                        eval {
                            handle_bmw_message($topic, $message);
                        };
                        if ($@) {
                            LOGERR("Error in message handler for $topic: $@");
                        }
                    }
                );
            };
            if ($@) {
                LOGERR("Failed to subscribe to topic $topic: $@");
                die "Subscription failed: $@";
            }
        } else {
            foreach my $vin (@vins) {
                my $topic = "$stream_username/$vin";
                LOGINF("Subscribing to topic: $topic");

                eval {
                    $bmw_mqtt->subscribe(
                        topic => $topic,
                        qos => 0,
                        callback => sub {
                            my ($topic, $message) = @_;
                            eval {
                                handle_bmw_message($topic, $message);
                            };
                            if ($@) {
                                LOGERR("Error in message handler for $topic: $@");
                            }
                        }
                    );
                };
                if ($@) {
                    LOGERR("Failed to subscribe to topic $topic: $@");
                    die "Subscription failed: $@";
                }
            }
        }

        LOGOK("Subscriptions registered");
        LOGINF("Note: Actual connection happens asynchronously in event loop");
    };

    if ($@) {
        LOGERR("Failed to setup BMW MQTT: $@");
        return 0;
    }

    return 1;
}

#
# Message Handling
#

sub handle_bmw_message {
    my ($topic, $message) = @_;

    LOGDEB("Received from BMW: $topic => $message");

    # Forward to LoxBerry MQTT Gateway
    forward_to_loxberry($topic, $message);
}

sub forward_to_loxberry {
    my ($topic, $message) = @_;

    return unless $loxberry_mqtt;

    # Transform topic if prefix is configured
    my $prefix = $current_config->{mqtt_topic_prefix} || 'bmw';
    my $loxberry_topic = "$prefix/$topic";

    # Publish to LoxBerry MQTT Gateway with retain flag
    # Using retain() ensures the last value is stored permanently by the broker
    eval {
        $loxberry_mqtt->retain($loxberry_topic, $message);
        LOGDEB("Forwarded to LoxBerry (retained): $loxberry_topic => $message");
    };

    if ($@) {
        LOGERR("Failed to forward message to LoxBerry: $@");
    }
}

#
# Cleanup
#

sub cleanup_connections {
    LOGINF("Cleaning up connections...");

    # Cleanup BMW MQTT connection
    # AnyEvent::MQTT has cleanup() method to destroy resources
    if ($bmw_mqtt) {
        eval {
            $bmw_mqtt->cleanup();
            undef $bmw_mqtt;
            LOGDEB("BMW MQTT connection cleaned up");
        };
        if ($@) {
            LOGERR("Error cleaning up BMW MQTT: $@");
        }
    }

    # Cleanup LoxBerry MQTT connection
    if ($loxberry_mqtt) {
        eval {
            # Net::MQTT::Simple connection cleanup (just undef is sufficient)
            undef $loxberry_mqtt;
            LOGDEB("LoxBerry MQTT connection closed");
        };
        if ($@) {
            LOGERR("Error closing LoxBerry MQTT: $@");
        }
    }

    $connection_active = 0;
    LOGDEB("Cleanup complete");
}

#
# Daemonization
#

sub daemonize {
    use POSIX qw(setsid);

    chdir '/' or die "Can't chdir to /: $!";
    open STDIN, '<', '/dev/null' or die "Can't read /dev/null: $!";
    open STDOUT, '>>', "$log_dir/bridge.log" or die "Can't write to log: $!";
    open STDERR, '>>&STDOUT' or die "Can't dup stdout: $!";

    # Enable auto-flush for daemon log output
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    defined(my $pid = fork) or die "Can't fork: $!";
    exit if $pid;

    setsid() or die "Can't start a new session: $!";

    # Write PID file
    my $pid_file = "$data_dir/bridge.pid";
    open(my $fh, '>', $pid_file) or die "Can't write PID file: $!";
    print $fh $$;
    close($fh);

    LOGINF("Daemonized with PID $$");
}

#
# Utility Functions
#

sub load_json {
    my ($filename) = @_;
    open(my $fh, '<', $filename) or die "Cannot read $filename: $!\n";
    my $content = do { local $/; <$fh> };
    close($fh);
    return decode_json($content);
}