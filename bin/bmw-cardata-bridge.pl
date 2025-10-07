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
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use File::Basename;
use POSIX qw(strftime);
use Getopt::Long;
use LoxBerry::Log;

# Enable auto-flush for immediate log output
$| = 1;
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Configuration
use constant {
    BMW_MQTT_PROTOCOL => 'mqtts',  # MQTT over SSL/TLS
    RECONNECT_DELAY => 10,          # Seconds to wait before reconnect
    TOKEN_CHECK_INTERVAL => 300,    # Check token expiry every 5 minutes
    TOKEN_REFRESH_MARGIN => 600,    # Refresh when < 10 minutes left
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
my $loxberry_udp_socket;
my $current_tokens;
my $current_config;
my $last_token_check = 0;
my $connection_active = 0;

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

# Initialize logging
my $log = LoxBerry::Log->new ( name => 'bmw-cardata-bridge' );

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

# Check if tokens need refresh
check_and_refresh_tokens();

# Connect to LoxBerry MQTT Gateway (UDP interface)
unless (setup_loxberry_connection()) {
    LOGCRIT("Failed to setup LoxBerry connection.");
    LOGEND;
    die "Failed to setup LoxBerry connection.\n";
}

# Connect to BMW CarData MQTT
unless (connect_to_bmw_mqtt()) {
    LOGCRIT("Failed to connect to BMW MQTT.");
    LOGEND;
    die "Failed to connect to BMW MQTT.\n";
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

        # Check if we need to reconnect (token expired)
        if (token_expired()) {
            LOGWARN("Token expired, need to reconnect...");
            $connection_active = 0;
            # Exit event loop to trigger reconnection
            $mqtt_cv->send if $mqtt_cv;
        }
    }
);

# Create AnyEvent condvar for event loop
$mqtt_cv = AnyEvent->condvar;

# Run the event loop (this blocks until $mqtt_cv->send is called)
LOGINF("Starting AnyEvent event loop...");
$mqtt_cv->recv;

# Cleanup and exit
cleanup_connections();
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

    my $tokens = eval { load_json($tokens_file) };
    return unless $tokens;

    my $now = time();
    my $expires_at = $tokens->{expires_at} || 0;
    my $time_left = $expires_at - $now;

    if ($time_left < TOKEN_REFRESH_MARGIN) {
        LOGINF("Token expires soon (${time_left}s left), triggering refresh...");

        # Call token-manager.pl to refresh
        my $token_manager = "$bin_dir/token-manager.pl";
        if (-x $token_manager) {
            my $result = system($token_manager, 'check');
            if ($result == 0) {
                LOGOK("Token refresh successful");
                # Reload tokens
                $current_tokens = load_json($tokens_file);
                # Trigger reconnection to use new id_token
                $connection_active = 0;
            } else {
                LOGERR("Token refresh failed");
            }
        } else {
            LOGERR("token-manager.pl not found or not executable");
        }
    }
}

sub token_expired {
    return 0 unless $current_tokens;
    my $now = time();
    my $expires_at = $current_tokens->{expires_at} || 0;
    return $expires_at < $now;
}

#
# LoxBerry MQTT Gateway Connection (UDP)
#

sub setup_loxberry_connection {
    LOGINF("Setting up LoxBerry MQTT Gateway connection...");

    # Try to use LoxBerry::IO if available
    my $mqtt_creds;
    eval {
        require LoxBerry::IO;
        $mqtt_creds = LoxBerry::IO::mqtt_connectiondetails();
    };

    if ($@ || !$mqtt_creds) {
        LOGWARN("LoxBerry::IO not available, using defaults");
        $mqtt_creds = {
            udpinport => 11884,  # Default LoxBerry MQTT UDP port
        };
    }

    my $udp_port = $mqtt_creds->{udpinport} || 11884;

    # Create UDP socket for publishing to LoxBerry MQTT Gateway
    $loxberry_udp_socket = IO::Socket::INET->new(
        PeerAddr => 'localhost',
        PeerPort => $udp_port,
        Proto => 'udp',
    );

    unless ($loxberry_udp_socket) {
        LOGERR("Failed to create UDP socket: $!");
        return 0;
    }

    LOGOK("LoxBerry MQTT Gateway connection ready (UDP port $udp_port)");
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

    eval {
        # Create MQTT connection with all required BMW parameters
        LOGINF("Creating MQTT connection with SSL/TLS, keepalive=30, clean_session=1...");

        $bmw_mqtt = AnyEvent::MQTT->new(
            host => $host,
            port => $port,
            user_name => $stream_username,
            password => $id_token,
            keep_alive_timer => 30,      # BMW expects 30 seconds keepalive
            clean_session => 1,           # Clean session flag
            timeout => 30,                # 30 second connection timeout
            # SSL/TLS options
            ssl => {
                verify_hostname => 1,
                SSL_verify_mode => SSL_VERIFY_PEER,
            },
            on_error => sub {
                my ($fatal, $message) = @_;
                if ($fatal) {
                    LOGCRIT("FATAL MQTT error: $message");
                    $connection_active = 0;
                } else {
                    LOGWARN("MQTT warning: $message");
                }
            },
        );

        LOGOK("MQTT connection object created successfully");

        # Subscribe to topics for each VIN
        my @vins = @{$current_config->{vins} || []};

        if (@vins == 0) {
            LOGWARN("No VINs configured, subscribing to all user topics");
            my $topic = "$stream_username/#";
            LOGINF("Subscribing to topic: $topic");

            $bmw_mqtt->subscribe(
                topic => $topic,
                qos => 0,
                callback => sub {
                    my ($topic, $message) = @_;
                    handle_bmw_message($topic, $message);
                }
            );
        } else {
            foreach my $vin (@vins) {
                my $topic = "$stream_username/$vin";
                LOGINF("Subscribing to topic: $topic");

                $bmw_mqtt->subscribe(
                    topic => $topic,
                    qos => 0,
                    callback => sub {
                        my ($topic, $message) = @_;
                        handle_bmw_message($topic, $message);
                    }
                );
            }
        }

        LOGOK("Successfully subscribed to all topics");
    };

    if ($@) {
        LOGERR("Failed to connect to BMW MQTT: $@");
        return 0;
    }

    LOGOK("BMW MQTT connection established");
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

    return unless $loxberry_udp_socket;

    # Transform topic if prefix is configured
    my $prefix = $current_config->{mqtt_topic_prefix} || 'bmw';
    my $loxberry_topic = "$prefix/$topic";

    # Format: "topic payload" for UDP interface
    my $udp_message = "$loxberry_topic $message";

    eval {
        $loxberry_udp_socket->send($udp_message);
        LOGDEB("Forwarded to LoxBerry: $loxberry_topic");
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

    if ($bmw_mqtt) {
        eval { $bmw_mqtt->disconnect() };
        undef $bmw_mqtt;
    }

    if ($loxberry_udp_socket) {
        eval { $loxberry_udp_socket->close() };
        undef $loxberry_udp_socket;
    }

    $connection_active = 0;
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
