#!/usr/bin/perl

use strict;
use warnings;
use Net::MQTT::Simple;
use LWP::UserAgent;
use JSON;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use File::Basename;
use POSIX qw(strftime);
use Getopt::Long;

# Configuration
use constant {
    CLIENT_ID => 'YOUR_CLIENT_ID_HERE',
    BMW_MQTT_PROTOCOL => 'mqtts',  # MQTT over SSL/TLS
    RECONNECT_DELAY => 10,          # Seconds to wait before reconnect
    TOKEN_CHECK_INTERVAL => 300,    # Check token expiry every 5 minutes
    TOKEN_REFRESH_MARGIN => 600,    # Refresh when < 10 minutes left
};

# Plugin directories
my $script_dir = dirname(__FILE__);
my $plugin_dir = dirname($script_dir);
my $data_dir = "$plugin_dir/data";
my $tokens_file = "$data_dir/tokens.json";
my $config_file = "$data_dir/config.json";

# Command line options
my $daemon = 0;
my $verbose = 0;
my $debug = 0;

GetOptions(
    'daemon|d' => \$daemon,
    'verbose|v' => \$verbose,
    'debug' => \$debug,
) or die "Usage: $0 [--daemon] [--verbose] [--debug]\n";

# Set verbose if debug
$verbose = 1 if $debug;

# Global state
my $running = 1;
my $bmw_mqtt;
my $loxberry_udp_socket;
my $current_tokens;
my $current_config;
my $last_token_check = 0;
my $connection_active = 0;

# Signal handlers
$SIG{TERM} = sub { log_msg("INFO", "Received SIGTERM, shutting down..."); $running = 0; };
$SIG{INT} = sub { log_msg("INFO", "Received SIGINT, shutting down..."); $running = 0; };
$SIG{HUP} = sub { log_msg("INFO", "Received SIGHUP, reloading configuration..."); reload_config(); };

# Main
log_msg("INFO", "=== BMW CarData MQTT Bridge Starting ===");
log_msg("INFO", "Daemon mode: " . ($daemon ? "yes" : "no"));
log_msg("INFO", "Verbose: " . ($verbose ? "yes" : "no"));

# Daemonize if requested
if ($daemon) {
    daemonize();
}

# Main loop
while ($running) {
    eval {
        # Load configuration and tokens
        unless (load_configuration()) {
            log_msg("ERROR", "Failed to load configuration, retrying in " . RECONNECT_DELAY . " seconds...");
            sleep(RECONNECT_DELAY);
            next;
        }

        # Check if tokens need refresh
        check_and_refresh_tokens();

        # Connect to LoxBerry MQTT Gateway (UDP interface)
        unless (setup_loxberry_connection()) {
            log_msg("ERROR", "Failed to setup LoxBerry connection, retrying in " . RECONNECT_DELAY . " seconds...");
            sleep(RECONNECT_DELAY);
            next;
        }

        # Connect to BMW CarData MQTT
        unless (connect_to_bmw_mqtt()) {
            log_msg("ERROR", "Failed to connect to BMW MQTT, retrying in " . RECONNECT_DELAY . " seconds...");
            cleanup_connections();
            sleep(RECONNECT_DELAY);
            next;
        }

        $connection_active = 1;
        log_msg("INFO", "Bridge is active and forwarding messages");

        # Keep connection alive and monitor
        while ($running && $connection_active) {
            sleep(1);

            # Periodically check token expiry
            if (time() - $last_token_check > TOKEN_CHECK_INTERVAL) {
                check_and_refresh_tokens();
            }

            # Check if we need to reconnect (token expired)
            if (token_expired()) {
                log_msg("WARN", "Token expired, reconnecting...");
                $connection_active = 0;
            }
        }

        cleanup_connections();

    };
    if ($@) {
        log_msg("ERROR", "Exception in main loop: $@");
        cleanup_connections();
        sleep(RECONNECT_DELAY) if $running;
    }
}

# Cleanup and exit
cleanup_connections();
log_msg("INFO", "=== BMW CarData MQTT Bridge Stopped ===");
exit 0;

#
# Configuration Management
#

sub load_configuration {
    log_msg("DEBUG", "Loading configuration...") if $debug;

    # Load tokens
    unless (-f $tokens_file) {
        log_msg("ERROR", "Tokens file not found: $tokens_file");
        log_msg("ERROR", "Please run oauth-init.pl and oauth-poll.pl first");
        return 0;
    }

    $current_tokens = eval { load_json($tokens_file) };
    if ($@) {
        log_msg("ERROR", "Failed to parse tokens file: $@");
        return 0;
    }

    unless (exists $current_tokens->{id_token} && exists $current_tokens->{gcid}) {
        log_msg("ERROR", "Invalid tokens file: missing id_token or gcid");
        return 0;
    }

    # Load config
    unless (-f $config_file) {
        log_msg("WARN", "Config file not found: $config_file");
        log_msg("WARN", "Using default configuration");
        $current_config = get_default_config();
    } else {
        $current_config = eval { load_json($config_file) };
        if ($@) {
            log_msg("ERROR", "Failed to parse config file: $@");
            return 0;
        }
    }

    # Validate required config
    unless (exists $current_config->{stream_host} && exists $current_config->{stream_port}) {
        log_msg("ERROR", "Invalid config: missing stream_host or stream_port");
        log_msg("ERROR", "Please configure the plugin via web interface");
        return 0;
    }

    log_msg("INFO", "Configuration loaded successfully");
    log_msg("DEBUG", "GCID: $current_tokens->{gcid}") if $debug;
    log_msg("DEBUG", "Stream host: $current_config->{stream_host}:$current_config->{stream_port}") if $debug;

    return 1;
}

sub reload_config {
    log_msg("INFO", "Reloading configuration...");
    $connection_active = 0;  # Trigger reconnect
}

sub get_default_config {
    return {
        stream_host => '',
        stream_port => 8883,
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
        log_msg("INFO", "Token expires soon (${time_left}s left), triggering refresh...");

        # Call token-manager.pl to refresh
        my $token_manager = "$script_dir/token-manager.pl";
        if (-x $token_manager) {
            my $result = system($token_manager, 'check');
            if ($result == 0) {
                log_msg("INFO", "Token refresh successful");
                # Reload tokens
                $current_tokens = load_json($tokens_file);
                # Trigger reconnection to use new id_token
                $connection_active = 0;
            } else {
                log_msg("ERROR", "Token refresh failed");
            }
        } else {
            log_msg("ERROR", "token-manager.pl not found or not executable");
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
    log_msg("INFO", "Setting up LoxBerry MQTT Gateway connection...");

    # Try to use LoxBerry::IO if available
    my $mqtt_creds;
    eval {
        require LoxBerry::IO;
        $mqtt_creds = LoxBerry::IO::mqtt_connectiondetails();
    };

    if ($@ || !$mqtt_creds) {
        log_msg("WARN", "LoxBerry::IO not available, using defaults");
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
        log_msg("ERROR", "Failed to create UDP socket: $!");
        return 0;
    }

    log_msg("INFO", "LoxBerry MQTT Gateway connection ready (UDP port $udp_port)");
    return 1;
}

#
# BMW CarData MQTT Connection
#

sub connect_to_bmw_mqtt {
    log_msg("INFO", "Connecting to BMW CarData MQTT...");

    my $host = $current_config->{stream_host};
    my $port = $current_config->{stream_port};
    my $gcid = $current_tokens->{gcid};
    my $id_token = $current_tokens->{id_token};

    unless ($host && $port) {
        log_msg("ERROR", "Missing BMW MQTT host or port in configuration");
        return 0;
    }

    my $broker_url = BMW_MQTT_PROTOCOL . "://$host:$port";
    log_msg("INFO", "Connecting to $broker_url as user $gcid");

    eval {
        $bmw_mqtt = Net::MQTT::Simple->new($broker_url);

        # Authenticate with GCID as username and ID token as password
        $bmw_mqtt->login($gcid, $id_token);

        log_msg("INFO", "Successfully authenticated to BMW MQTT");

        # Subscribe to topics for each VIN
        my @vins = @{$current_config->{vins} || []};

        if (@vins == 0) {
            log_msg("WARN", "No VINs configured, subscribing to all user topics");
            my $topic = "$gcid/#";
            log_msg("INFO", "Subscribing to topic: $topic");
            $bmw_mqtt->subscribe($topic, \&handle_bmw_message);
        } else {
            foreach my $vin (@vins) {
                my $topic = "$gcid/$vin";
                log_msg("INFO", "Subscribing to topic: $topic");
                $bmw_mqtt->subscribe($topic, \&handle_bmw_message);
            }
        }

        # Start message loop in background
        # Net::MQTT::Simple handles this internally
    };

    if ($@) {
        log_msg("ERROR", "Failed to connect to BMW MQTT: $@");
        return 0;
    }

    log_msg("INFO", "BMW MQTT connection established");
    return 1;
}

#
# Message Handling
#

sub handle_bmw_message {
    my ($topic, $message) = @_;

    log_msg("DEBUG", "Received from BMW: $topic => $message") if $debug;

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
        log_msg("DEBUG", "Forwarded to LoxBerry: $loxberry_topic") if $debug;
    };

    if ($@) {
        log_msg("ERROR", "Failed to forward message to LoxBerry: $@");
    }
}

#
# Cleanup
#

sub cleanup_connections {
    log_msg("INFO", "Cleaning up connections...");

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
    open STDOUT, '>>', '/opt/loxberry/log/plugins/loxberry-bmw-cardata/bridge.log' or die "Can't write to log: $!";
    open STDERR, '>>&STDOUT' or die "Can't dup stdout: $!";

    defined(my $pid = fork) or die "Can't fork: $!";
    exit if $pid;

    setsid() or die "Can't start a new session: $!";

    # Write PID file
    my $pid_file = "$data_dir/bridge.pid";
    open(my $fh, '>', $pid_file) or die "Can't write PID file: $!";
    print $fh $$;
    close($fh);

    log_msg("INFO", "Daemonized with PID $$");
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

sub log_msg {
    my ($level, $message) = @_;

    # Skip debug messages unless debug mode
    return if $level eq 'DEBUG' && !$debug;

    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $log_line = "[$timestamp] [$level] $message\n";

    print $log_line;
}
