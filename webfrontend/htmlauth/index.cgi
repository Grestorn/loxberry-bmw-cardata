#!/usr/bin/perl

# BMW CarData Plugin Web Interface
# Handles OAuth authentication, configuration, and status display

use strict;
use warnings;
use CGI;
use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::JSON;
use JSON;
use File::Basename;

# CGI and Template
my $cgi = CGI->new;
my $template = HTML::Template->new(
    filename => "$lbptemplatedir/index.html",
    global_vars => 1,
    loop_context_vars => 1,
    die_on_bad_params => 0
);

# Language
my %L = LoxBerry::Web::readlanguage($template, "language.ini");

# Plugin data
my $plugin = LoxBerry::System::plugindata();
my $plugintitle = "$plugin->{PLUGINDB_TITLE} $plugin->{PLUGINDB_VERSION}";
my $helplink = "https://bmw-cardata.bmwgroup.com/customer/public/api-documentation";
my $helptemplate = "help.html";

# Navigation
our %navbar;
$navbar{10}{Name} = $L{'NAVIGATION.MAIN'};
$navbar{10}{URL} = 'index.cgi';
$navbar{20}{Name} = $L{'NAVIGATION.LOGS'};
$navbar{20}{URL} = 'index.cgi?page=logs';

# File paths
my $data_dir = "$lbpdatadir";
my $bin_dir = "$lbpbindir";
my $tokens_file = "$data_dir/tokens.json";
my $config_file = "$data_dir/config.json";

# Handle form submissions
my $action = $cgi->param('action') || '';
my $page = $cgi->param('page') || 'main';

if ($action eq 'save_config') {
    handle_save_config();
} elsif ($action eq 'request_device_code') {
    handle_request_device_code();
} elsif ($action eq 'check_oauth') {
    handle_check_oauth();
} elsif ($action eq 'refresh_token') {
    handle_refresh_token();
} elsif ($action eq 'start_bridge') {
    handle_start_bridge();
} elsif ($action eq 'stop_bridge') {
    handle_stop_bridge();
} elsif ($action eq 'restart_bridge') {
    handle_restart_bridge();
}

# Load current status (create default config if not exists)
my $tokens = load_tokens();
my $config = load_or_create_config();
my $bridge_status = get_bridge_status();
my $device_code_data = load_device_code();

# Prepare template variables
prepare_template_vars($page, $tokens, $config, $bridge_status, $device_code_data);

# Output
LoxBerry::Web::lbheader($plugintitle, $helplink, $helptemplate);
print $template->output();
LoxBerry::Web::lbfooter();

exit;

#
# Action Handlers
#

sub handle_save_config {
    # Load old config to check if client_id changed
    my $old_config = load_config();
    my $old_client_id = $old_config ? ($old_config->{client_id} || '') : '';

    my $new_config = {
        client_id => $cgi->param('client_id') || '',
        stream_host => $cgi->param('stream_host') || '',
        stream_port => int($cgi->param('stream_port') || 0),
        stream_username => $cgi->param('stream_username') || '',
        vins => [],
        mqtt_topic_prefix => $cgi->param('mqtt_topic_prefix') || '',
    };

    # Parse VINs (one per line)
    my $vins_text = $cgi->param('vins') || '';
    my @vins = grep { $_ ne '' } map { s/^\s+|\s+$//gr } split(/\n/, $vins_text);
    $new_config->{vins} = \@vins;

    # Save config
    save_config($new_config);

    $template->param('SAVE_SUCCESS' => 1);
    $template->param('SAVE_MESSAGE' => $L{'CONFIG.SAVED'});

    # Check if client_id changed and is not empty
    my $new_client_id = $new_config->{client_id};
    if ($new_client_id && $new_client_id ne '' && $new_client_id ne $old_client_id) {
        # Client ID changed - automatically start OAuth initialization
        $template->param('CLIENT_ID_CHANGED' => 1);
        handle_request_device_code();
    }
}

sub handle_request_device_code {
    # Run oauth-init.pl
    my $output = qx{$bin_dir/oauth-init.pl 2>&1};
    my $exit_code = $? >> 8;

    if ($exit_code == 0) {
        # Load device code response to extract verification URI
        my $device_file = "$data_dir/device_code.json";
        if (-f $device_file) {
            my $device_data = eval { load_json($device_file) };
            if ($device_data) {
                # Extract verification URI and user code
                my $verification_uri = $device_data->{verification_uri_complete} || $device_data->{verification_uri};
                my $user_code = $device_data->{user_code} || '';
                my $expires_in = $device_data->{expires_in} || 0;

                $template->param('DEVICE_CODE_SUCCESS' => 1);
                $template->param('OAUTH_VERIFICATION_URI' => $verification_uri);
                $template->param('OAUTH_USER_CODE' => $user_code);
                $template->param('OAUTH_EXPIRES_MINUTES' => int($expires_in / 60));
                $template->param('DEVICE_CODE_OUTPUT' => $output);
            }
        }
    } else {
        $template->param('DEVICE_CODE_ERROR' => 1);
        $template->param('DEVICE_CODE_OUTPUT' => $output);
    }
}

sub handle_check_oauth {
    # Run oauth-poll.pl
    my $output = qx{$bin_dir/oauth-poll.pl 2>&1};
    my $exit_code = $? >> 8;

    if ($exit_code == 0) {
        $template->param('OAUTH_POLL_SUCCESS' => 1);
        $template->param('OAUTH_POLL_OUTPUT' => $output);
    } else {
        $template->param('OAUTH_POLL_ERROR' => 1);
        $template->param('OAUTH_POLL_OUTPUT' => $output);
    }
}

sub handle_start_bridge {
    my $output = qx{$bin_dir/bridge-control.sh start 2>&1};
    $template->param('BRIDGE_ACTION_OUTPUT' => $output);
}

sub handle_stop_bridge {
    my $output = qx{$bin_dir/bridge-control.sh stop 2>&1};
    $template->param('BRIDGE_ACTION_OUTPUT' => $output);
}

sub handle_restart_bridge {
    my $output = qx{$bin_dir/bridge-control.sh restart 2>&1};
    $template->param('BRIDGE_ACTION_OUTPUT' => $output);
}

sub handle_refresh_token {
    # Run token-manager.pl refresh --force
    my $output = qx{$bin_dir/token-manager.pl refresh --force 2>&1};
    my $exit_code = $? >> 8;

    if ($exit_code == 0) {
        $template->param('TOKEN_REFRESH_SUCCESS' => 1);
        $template->param('TOKEN_REFRESH_OUTPUT' => $output);
    } else {
        $template->param('TOKEN_REFRESH_ERROR' => 1);
        $template->param('TOKEN_REFRESH_OUTPUT' => $output);
    }
}

#
# Template Preparation
#

sub prepare_template_vars {
    my ($page, $tokens, $config, $bridge_status, $device_code_data) = @_;

    # Current page
    $template->param('PAGE_MAIN' => $page eq 'main');
    $template->param('PAGE_LOGS' => $page eq 'logs');

    # Device code status
    if ($device_code_data && exists $device_code_data->{device_code}) {
        my $now = time();
        # Check if device code has timestamp (creation time)
        # If not, we can't determine expiry, so assume it's still valid
        my $device_code_valid = 1;

        $template->param('DEVICE_CODE_EXISTS' => 1);
        $template->param('DEVICE_CODE_VALID' => $device_code_valid);
    }

    # Authentication status
    if ($tokens && exists $tokens->{gcid}) {
        my $now = time();
        my $expires_at = $tokens->{expires_at} || 0;
        my $refresh_expires_at = $tokens->{refresh_expires_at} || 0;

        my $token_valid = $expires_at > $now;
        my $refresh_valid = $refresh_expires_at > $now;

        $template->param('AUTH_STATUS' => $token_valid ? 'valid' : 'expired');
        $template->param('AUTH_VALID' => $token_valid);
        $template->param('AUTH_EXPIRED' => !$token_valid);
        $template->param('GCID' => $tokens->{gcid});

        # Show current access token for manual API testing
        if (exists $tokens->{access_token}) {
            $template->param('ACCESS_TOKEN' => $tokens->{access_token});
        }

        if ($token_valid) {
            my $time_left = $expires_at - $now;
            my $minutes_left = int($time_left / 60);
            $template->param('TOKEN_EXPIRES_MINUTES' => $minutes_left);
        }

        if ($refresh_valid) {
            my $time_left = $refresh_expires_at - $now;
            my $days_left = int($time_left / 86400);
            $template->param('REFRESH_EXPIRES_DAYS' => $days_left);
        } else {
            $template->param('REFRESH_EXPIRED' => 1);
        }
    } else {
        $template->param('AUTH_STATUS' => 'none');
        $template->param('AUTH_NONE' => 1);
    }

    # Configuration (always exists due to load_or_create_config)
    if ($config) {
        $template->param('CLIENT_ID' => $config->{client_id});
        $template->param('STREAM_HOST' => $config->{stream_host});
        $template->param('STREAM_PORT' => $config->{stream_port});
        $template->param('STREAM_USERNAME' => $config->{stream_username});
        $template->param('MQTT_TOPIC_PREFIX' => $config->{mqtt_topic_prefix});

        if ($config->{vins} && ref($config->{vins}) eq 'ARRAY') {
            $template->param('VINS' => join("\n", @{$config->{vins}}));
        }

        my $config_has_client_id = $config->{client_id} && $config->{client_id} ne '';
        my $config_complete = $config_has_client_id && $config->{stream_host} &&
                             $config->{stream_username};

        $template->param('CONFIG_HAS_CLIENT_ID' => $config_has_client_id);
        $template->param('CONFIG_COMPLETE' => $config_complete);
    }

    # Bridge status
    $template->param('BRIDGE_RUNNING' => $bridge_status->{running});
    $template->param('BRIDGE_STOPPED' => !$bridge_status->{running});
    $template->param('BRIDGE_PID' => $bridge_status->{pid} || 'N/A');

    # Logs
    if ($page eq 'logs') {
        my $bridge_log = read_log("$lbplogdir/bridge.log", 50);
        my $token_log = read_log("$lbplogdir/token-refresh.log", 50);

        $template->param('BRIDGE_LOG' => $bridge_log);
        $template->param('TOKEN_LOG' => $token_log);
    }
}

#
# Helper Functions
#

sub load_tokens {
    return undef unless -f $tokens_file;

    my $json_text;
    if (open(my $fh, '<', $tokens_file)) {
        local $/;
        $json_text = <$fh>;
        close($fh);
    } else {
        return undef;
    }

    return eval { decode_json($json_text) };
}

sub load_config {
    return undef unless -f $config_file;

    my $json_text;
    if (open(my $fh, '<', $config_file)) {
        local $/;
        $json_text = <$fh>;
        close($fh);
    } else {
        return undef;
    }

    return eval { decode_json($json_text) };
}

sub load_or_create_config {
    # Try to load existing config
    my $config = load_config();
    return $config if $config;

    # Create default config if not exists
    my $default_config = {
        client_id => '',
        stream_host => 'customer.streaming-cardata.bmwgroup.com',
        stream_port => 9000,
        stream_username => '',
        vins => [],
        mqtt_topic_prefix => 'bmw',
    };

    # Ensure data directory exists
    unless (-d $data_dir) {
        require File::Path;
        File::Path::make_path($data_dir);
    }

    # Save default config
    save_config($default_config);

    return $default_config;
}

sub load_json {
    my ($filename) = @_;
    return undef unless -f $filename;

    my $json_text;
    if (open(my $fh, '<', $filename)) {
        local $/;
        $json_text = <$fh>;
        close($fh);
    } else {
        return undef;
    }

    return eval { decode_json($json_text) };
}

sub save_config {
    my ($config) = @_;

    open(my $fh, '>', $config_file) or die "Cannot write config: $!";
    print $fh JSON->new->pretty->encode($config);
    close($fh);

    chmod(0600, $config_file);
}

sub get_bridge_status {
    my $pid_file = "$data_dir/bridge.pid";
    my $status = {
        running => 0,
        pid => undef,
    };

    if (-f $pid_file) {
        open(my $fh, '<', $pid_file);
        my $pid = <$fh>;
        close($fh);

        chomp($pid);

        # Check if process is running
        if (kill(0, $pid)) {
            $status->{running} = 1;
            $status->{pid} = $pid;
        }
    }

    return $status;
}

sub read_log {
    my ($logfile, $lines) = @_;

    return "Log file not found" unless -f $logfile;

    my $output = qx{tail -n $lines "$logfile" 2>&1};
    return $output || "Empty log file";
}

sub load_device_code {
    my $device_file = "$data_dir/device_code.json";
    return undef unless -f $device_file;

    my $json_text;
    if (open(my $fh, '<', $device_file)) {
        local $/;
        $json_text = <$fh>;
        close($fh);
    } else {
        return undef;
    }

    return eval { decode_json($json_text) };
}

