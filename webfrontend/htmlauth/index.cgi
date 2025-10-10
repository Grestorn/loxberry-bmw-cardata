#!/usr/bin/perl

# BMW CarData Plugin Web Interface
# Handles OAuth authentication, configuration, and status display

use strict;
use warnings;
use CGI;
use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::JSON;
use LoxBerry::Log;
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

# Get page parameter first (needed for navigation)
my $page = $cgi->param('page') || 'main';
my $action = $cgi->param('action') || '';

# Navigation
our %navbar;
$navbar{10}{Name} = $L{'NAVIGATION.MAIN'};
$navbar{10}{URL} = 'index.cgi';
$navbar{10}{active} = 1 if $page eq 'main';
$navbar{20}{Name} = $L{'NAVIGATION.LOGS'};
$navbar{20}{URL} = 'index.cgi?page=logs';
$navbar{20}{active} = 1 if $page eq 'logs';

# File paths
my $data_dir = "$lbpdatadir";
my $bin_dir = "$lbpbindir";
my $tokens_file = "$data_dir/tokens.json";
my $config_file = "$data_dir/config.json";

# Handle form submissions

if ($action eq 'save_config') {
    handle_save_config();
} elsif ($action eq 'request_device_code') {
    handle_request_device_code();
} elsif ($action eq 'check_oauth') {
    handle_check_oauth();
} elsif ($action eq 'refresh_token') {
    handle_refresh_token();
} elsif ($action eq 'reset_auth') {
    handle_reset_auth();
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
        # Only show message if there was a previous client_id (not first time entry)
        if ($old_client_id && $old_client_id ne '') {
            # Client ID changed - reset OAuth state using shared function
            reset_authentication_files();

            $template->param('CLIENT_ID_CHANGED' => 1);
            $template->param('CLIENT_ID_CHANGE_MESSAGE' => $L{'STATUS.CLIENT_ID_CHANGED_INFO'});
        }
    }
}

sub handle_request_device_code {
    # Run oauth-init.pl
    system("$bin_dir/oauth-init.pl >/dev/null 2>&1");
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
            }
        }
    } else {
        $template->param('DEVICE_CODE_ERROR' => 1);
    }
}

sub handle_check_oauth {
    # Run oauth-poll.pl
    system("$bin_dir/oauth-poll.pl >/dev/null 2>&1");
    my $exit_code = $? >> 8;

    # Generate log button to view results
    my $log_button = LoxBerry::Web::logfile_button_html(
        NAME => 'oauth-poll',
        PACKAGE => $lbpplugindir
    );

    if ($exit_code == 0) {
        $template->param('OAUTH_POLL_SUCCESS' => 1);
        $template->param('OAUTH_POLL_LOG_BUTTON' => $log_button);

        # Auto-start bridge after successful registration
        my $bridge_status = get_bridge_status();
        unless ($bridge_status->{running}) {
            system("$bin_dir/bridge-control.sh start >/dev/null 2>&1");
        }
    } else {
        $template->param('OAUTH_POLL_ERROR' => 1);
        $template->param('OAUTH_POLL_LOG_BUTTON' => $log_button);
    }
}

sub handle_start_bridge {
    system("$bin_dir/bridge-control.sh start >/dev/null 2>&1");
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        $template->param('BRIDGE_START_ERROR' => 1);
    }
}

sub handle_stop_bridge {
    system("$bin_dir/bridge-control.sh stop >/dev/null 2>&1");
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        $template->param('BRIDGE_STOP_ERROR' => 1);
    }
}

sub handle_restart_bridge {
    system("$bin_dir/bridge-control.sh restart >/dev/null 2>&1");
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        $template->param('BRIDGE_RESTART_ERROR' => 1);
    }
}

sub handle_refresh_token {
    # Run token-manager.pl refresh --force
    system("$bin_dir/token-manager.pl refresh --force >/dev/null 2>&1");
    my $exit_code = $? >> 8;

    # Generate log button to view results
    my $log_button = LoxBerry::Web::logfile_button_html(
        NAME => 'token-manager',
        PACKAGE => $lbpplugindir
    );

    if ($exit_code == 0) {
        $template->param('TOKEN_REFRESH_SUCCESS' => 1);
        $template->param('TOKEN_REFRESH_LOG_BUTTON' => $log_button);
    } else {
        $template->param('TOKEN_REFRESH_ERROR' => 1);
        $template->param('TOKEN_REFRESH_LOG_BUTTON' => $log_button);
    }
}

sub handle_reset_auth {
    # Reset authentication using shared function
    reset_authentication_files();

    $template->param('AUTH_RESET_SUCCESS' => 1);
}

#
# Helper Functions
#

sub reset_authentication_files {
    # Stop the bridge if running
    system("$bin_dir/bridge-control.sh stop >/dev/null 2>&1");

    # Remove authentication files
    unlink($tokens_file) if -f $tokens_file;
    unlink("$data_dir/device_code.json") if -f "$data_dir/device_code.json";
    unlink("$data_dir/pkce.json") if -f "$data_dir/pkce.json";
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

        # Set verification URI for OAuth flow (always shown in step list)
        my $verification_uri = $device_code_data->{verification_uri_complete} || $device_code_data->{verification_uri};
        if ($verification_uri) {
            $template->param('OAUTH_VERIFICATION_URI' => $verification_uri);

            # Calculate minutes until expiry
            my $expires_in = $device_code_data->{expires_in} || 0;
            $template->param('OAUTH_EXPIRES_MINUTES' => int($expires_in / 60));
        }
    }

    # OAuth Step Status
    # Step 1 & 2: Config saved with client_id
    my $step1_2_done = $config && $config->{client_id} && $config->{client_id} ne '';
    $template->param('OAUTH_STEP1_2_DONE' => $step1_2_done);

    # Step 3: Device code requested
    my $step3_done = $device_code_data && exists $device_code_data->{device_code};
    $template->param('OAUTH_STEP3_DONE' => $step3_done);

    # Step 4: User clicked BMW login button (we track this via session/cookie or assume done if step 3 done)
    # For simplicity, we consider step 4 done if device code exists and user has verification URI
    my $step4_done = $step3_done && ($device_code_data->{verification_uri} || $device_code_data->{verification_uri_complete});
    $template->param('OAUTH_STEP4_DONE' => $step4_done);

    # Step 5: Tokens retrieved (authentication complete)
    my $step5_done = $tokens && exists $tokens->{gcid};
    $template->param('OAUTH_STEP5_DONE' => $step5_done);

    # Determine current step (next step to do)
    my $current_step = 1;
    if ($step5_done) {
        $current_step = 0; # All done
    } elsif ($step4_done) {
        $current_step = 5;
    } elsif ($step3_done) {
        $current_step = 4;
    } elsif ($step1_2_done) {
        $current_step = 3;
    }

    $template->param('OAUTH_CURRENT_STEP' => $current_step);
    $template->param('OAUTH_STEP1_CURRENT' => $current_step == 1);
    $template->param('OAUTH_STEP2_CURRENT' => $current_step == 2);
    $template->param('OAUTH_STEP3_CURRENT' => $current_step == 3);
    $template->param('OAUTH_STEP4_CURRENT' => $current_step == 4);
    $template->param('OAUTH_STEP5_CURRENT' => $current_step == 5);

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

        # Show current ID token for MQTT authentication
        if (exists $tokens->{id_token}) {
            $template->param('ID_TOKEN' => $tokens->{id_token});
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

    # Logs - separate pages for each log type
    if ($page eq 'logs') {
        # Bridge logs page
        my $loglist_html = LoxBerry::Web::loglist_html();
        $template->param('LOGLIST_HTML' => $loglist_html);
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