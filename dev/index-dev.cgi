#!/usr/bin/env perl

# Local Development Wrapper for BMW CarData Plugin Web Interface
# This script allows running the plugin web interface locally on Windows
# Supports multiple BMW accounts (multi-tenant)

use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';
use FindBin qw($RealBin);
use lib "$RealBin";

# Load the mock LoxBerry modules BEFORE loading CGI
BEGIN {
    # Add dev directory to @INC for mock modules
    unshift @INC, "$RealBin";

    # Export LoxBerry path variables
    require LoxBerryMock;
    LoxBerryMock->import();

    # Make mock variables available globally
    our $lbptemplatedir = $LoxBerryMock::lbptemplatedir;
    our $lbpdatadir = $LoxBerryMock::lbpdatadir;
    our $lbpbindir = $LoxBerryMock::lbpbindir;
    our $lbplogdir = $LoxBerryMock::lbplogdir;
    our $lbpconfigdir = $LoxBerryMock::lbpconfigdir;
    our $lbpplugindir = $LoxBerryMock::lbpplugindir;
}

# Now we can safely load the main CGI script
use CGI;
use HTML::Template;
use JSON;
use File::Basename;
use File::Path qw(make_path rmtree);

# CGI and Template
my $cgi = CGI->new;
my $template = HTML::Template->new(
    filename => "$LoxBerryMock::lbptemplatedir/index.html",
    global_vars => 1,
    loop_context_vars => 1,
    die_on_bad_params => 0,
    utf8 => 1
);

# Language
my %L = LoxBerry::Web::readlanguage($template, "language.ini");

# Plugin data
my $plugin = LoxBerry::System::plugindata();
my $plugintitle = "$plugin->{PLUGINDB_TITLE} $plugin->{PLUGINDB_VERSION}";
my $helplink = "https://bmw-cardata.bmwgroup.com/customer/public/api-documentation";
my $helptemplate = "help.html";

# Get page and action parameters
my $page = $cgi->param('page') || 'main';
my $action = $cgi->param('action') || '';

# Base directories
my $data_dir = $LoxBerryMock::lbpdatadir;
my $bin_dir = $LoxBerryMock::lbpbindir;
my $accounts_base = "$data_dir/accounts";

# Ensure accounts directory exists
unless (-d $accounts_base) {
    make_path($accounts_base);
}

# Account handling
my $account_id = $cgi->param('account') || '';
my @accounts = list_accounts();

# Handle account creation first (before account_id validation)
if ($action eq 'create_account') {
    handle_create_account();
    @accounts = list_accounts();
}

# Handle account deletion
if ($action eq 'delete_account' && $account_id) {
    handle_delete_account();
    @accounts = list_accounts();
    $account_id = '';
}

# If no account selected but accounts exist, use the first one
if (!$account_id && @accounts > 0) {
    $account_id = $accounts[0]->{id};
}

# Account-scoped paths (only set if we have an account)
my $account_dir = '';
my $tokens_file = '';
my $config_file = '';

if ($account_id) {
    $account_dir = "$accounts_base/$account_id";
    $tokens_file = "$account_dir/tokens.json";
    $config_file = "$account_dir/config.json";
}

# Navigation (include account in URLs if selected)
our %navbar;
my $account_param = $account_id ? "&account=$account_id" : '';
$navbar{10}{Name} = $L{'NAVIGATION.MAIN'};
$navbar{10}{URL} = "index-dev.cgi?page=main$account_param";
$navbar{10}{active} = 1 if $page eq 'main';
$navbar{20}{Name} = $L{'NAVIGATION.LOGS'};
$navbar{20}{URL} = "index-dev.cgi?page=logs$account_param";
$navbar{20}{active} = 1 if $page eq 'logs';

# Handle form submissions (only if account is selected)
if ($account_id && -d $account_dir) {
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
}

# Load current status (only if account selected)
my $tokens;
my $config;
my $bridge_status = { running => 0, pid => undef };
my $device_code_data;

if ($account_id && -d $account_dir) {
    $tokens = load_tokens();
    $config = load_or_create_config();
    $bridge_status = get_bridge_status();
    $device_code_data = load_device_code();
}

# Prepare template variables
prepare_account_vars();
prepare_template_vars($page, $tokens, $config, $bridge_status, $device_code_data) if $account_id;

# Output with navigation bar
LoxBerry::Web::lbheader($plugintitle, $helplink, $helptemplate);

# Render navigation
if (%navbar) {
    print qq{<div class="navbar">};
    for my $key (sort { $a <=> $b } keys %navbar) {
        my $name = $navbar{$key}{Name};
        my $url = $navbar{$key}{URL};
        my $active = $navbar{$key}{active} ? ' class="active"' : '';
        my $target = $navbar{$key}{target} ? qq{ target="$navbar{$key}{target}"} : '';
        print qq{<a href="$url"$active$target>$name</a>};
    }
    print qq{</div>};
}

print $template->output();
LoxBerry::Web::lbfooter();

exit;

#
# Account Management
#

sub list_accounts {
    my @result;
    return @result unless -d $accounts_base;

    opendir(my $dh, $accounts_base) or return @result;
    my @dirs = sort grep { -d "$accounts_base/$_" && $_ !~ /^\./ } readdir($dh);
    closedir($dh);

    foreach my $dir (@dirs) {
        my $acct = { id => $dir, name => $dir };
        my $cfg_file = "$accounts_base/$dir/config.json";
        if (-f $cfg_file) {
            my $cfg = eval { load_json($cfg_file) };
            if ($cfg && $cfg->{account_name}) {
                $acct->{name} = $cfg->{account_name};
            }
        }
        push @result, $acct;
    }

    return @result;
}

sub generate_slug {
    my ($name) = @_;
    my $slug = lc($name);
    $slug =~ s/[^a-z0-9]+/-/g;
    $slug =~ s/^-+|-+$//g;
    $slug = substr($slug, 0, 32);
    $slug = 'account' if $slug eq '';

    my $base_slug = $slug;
    my $counter = 2;
    while (-d "$accounts_base/$slug") {
        $slug = "$base_slug-$counter";
        $counter++;
    }

    return $slug;
}

sub handle_create_account {
    my $account_name = $cgi->param('account_name') || '';
    $account_name =~ s/^\s+|\s+$//g;

    unless ($account_name) {
        $template->param('ACCOUNT_CREATE_ERROR' => 1);
        return;
    }

    my $slug = generate_slug($account_name);
    my $new_dir = "$accounts_base/$slug";
    make_path($new_dir);

    my $default_config = {
        account_name => $account_name,
        client_id => '',
        stream_host => 'customer.streaming-cardata.bmwgroup.com',
        stream_port => 9000,
        stream_username => '',
        vins => [],
        mqtt_topic_prefix => "bmw-$slug",
    };

    my $cfg_file = "$new_dir/config.json";
    open(my $fh, '>', $cfg_file) or die "Cannot write config: $!";
    print $fh JSON->new->pretty->encode($default_config);
    close($fh);
    chmod(0600, $cfg_file);

    $account_id = $slug;
    $account_dir = $new_dir;
    $tokens_file = "$account_dir/tokens.json";
    $config_file = "$account_dir/config.json";

    $template->param('ACCOUNT_CREATED' => 1);
    $template->param('ACCOUNT_CREATED_NAME' => $account_name);
}

sub handle_delete_account {
    return unless $account_id && -d "$accounts_base/$account_id";

    rmtree("$accounts_base/$account_id");

    $template->param('ACCOUNT_DELETED' => 1);
}

sub prepare_account_vars {
    my @accounts_loop;
    foreach my $acct (@accounts) {
        push @accounts_loop, {
            ACCOUNT_ID => $acct->{id},
            ACCOUNT_NAME => $acct->{name},
            ACCOUNT_ACTIVE => ($account_id eq $acct->{id}) ? 1 : 0,
        };
    }
    $template->param('ACCOUNTS_LOOP' => \@accounts_loop);
    $template->param('HAS_ACCOUNTS' => scalar @accounts > 0);
    $template->param('NO_ACCOUNTS' => scalar @accounts == 0);
    $template->param('CURRENT_ACCOUNT_ID' => $account_id);
    $template->param('CURRENT_ACCOUNT_NAME' => '');

    foreach my $acct (@accounts) {
        if ($acct->{id} eq $account_id) {
            $template->param('CURRENT_ACCOUNT_NAME' => $acct->{name});
            last;
        }
    }
}

#
# Action Handlers
#

sub handle_save_config {
    my $old_config = load_config();
    my $old_client_id = $old_config ? ($old_config->{client_id} || '') : '';

    my $account_name = $old_config ? ($old_config->{account_name} || $account_id) : $account_id;

    my $new_config = {
        account_name => $account_name,
        client_id => $cgi->param('client_id') || '',
        stream_host => $cgi->param('stream_host') || '',
        stream_port => int($cgi->param('stream_port') || 0),
        stream_username => $cgi->param('stream_username') || '',
        vins => [],
        mqtt_topic_prefix => $cgi->param('mqtt_topic_prefix') || '',
    };

    my $vins_text = $cgi->param('vins') || '';
    my @vins = grep { $_ ne '' } map { s/^\s+|\s+$//gr } split(/\n/, $vins_text);
    $new_config->{vins} = \@vins;

    save_config($new_config);

    $template->param('SAVE_SUCCESS' => 1);
    $template->param('SAVE_MESSAGE' => $L{'CONFIG.SAVED'});

    my $new_client_id = $new_config->{client_id};
    if ($new_client_id && $new_client_id ne '' && $new_client_id ne $old_client_id) {
        if ($old_client_id && $old_client_id ne '') {
            reset_authentication_files();

            $template->param('CLIENT_ID_CHANGED' => 1);
            $template->param('CLIENT_ID_CHANGE_MESSAGE' => $L{'STATUS.CLIENT_ID_CHANGED_INFO'});
        }
    }
}

sub handle_request_device_code {
    $template->param('DEVICE_CODE_ERROR' => 1);
    # Note: OAuth scripts won't work in local dev mode
}

sub handle_check_oauth {
    $template->param('OAUTH_POLL_ERROR' => 1);
    # Note: OAuth scripts won't work in local dev mode
}

sub handle_start_bridge {
    $template->param('BRIDGE_START_ERROR' => 1);
    # Note: Bridge control won't work in local dev mode
}

sub handle_stop_bridge {
    $template->param('BRIDGE_STOP_ERROR' => 1);
    # Note: Bridge control won't work in local dev mode
}

sub handle_restart_bridge {
    $template->param('BRIDGE_RESTART_ERROR' => 1);
    # Note: Bridge control won't work in local dev mode
}

sub handle_refresh_token {
    $template->param('TOKEN_REFRESH_ERROR' => 1);
    # Note: Token manager won't work in local dev mode
}

sub handle_reset_auth {
    reset_authentication_files();

    $template->param('AUTH_RESET_SUCCESS' => 1);
}

#
# Helper Functions
#

sub reset_authentication_files {
    unlink($tokens_file) if -f $tokens_file;
    unlink("$account_dir/device_code.json") if -f "$account_dir/device_code.json";
    unlink("$account_dir/pkce.json") if -f "$account_dir/pkce.json";
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
        my $device_code_valid = 1;

        $template->param('DEVICE_CODE_EXISTS' => 1);
        $template->param('DEVICE_CODE_VALID' => $device_code_valid);

        my $verification_uri = $device_code_data->{verification_uri_complete} || $device_code_data->{verification_uri};
        if ($verification_uri) {
            $template->param('OAUTH_VERIFICATION_URI' => $verification_uri);

            my $expires_in = $device_code_data->{expires_in} || 0;
            $template->param('OAUTH_EXPIRES_MINUTES' => int($expires_in / 60));
        }
    }

    # OAuth Step Status
    my $step1_2_done = $config && $config->{client_id} && $config->{client_id} ne '';
    $template->param('OAUTH_STEP1_2_DONE' => $step1_2_done);

    my $step3_done = $device_code_data && exists $device_code_data->{device_code};
    $template->param('OAUTH_STEP3_DONE' => $step3_done);

    my $step4_done = $step3_done && ($device_code_data->{verification_uri} || $device_code_data->{verification_uri_complete});
    $template->param('OAUTH_STEP4_DONE' => $step4_done);

    my $step5_done = $tokens && exists $tokens->{gcid};
    $template->param('OAUTH_STEP5_DONE' => $step5_done);

    my $current_step = 1;
    if ($step5_done) {
        $current_step = 0;
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

        if (exists $tokens->{access_token}) {
            $template->param('ACCESS_TOKEN' => $tokens->{access_token});
        }

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

    # Configuration
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
    my $config = load_config();
    return $config if $config;

    my $default_config = {
        account_name => $account_id,
        client_id => '',
        stream_host => 'customer.streaming-cardata.bmwgroup.com',
        stream_port => 9000,
        stream_username => '',
        vins => [],
        mqtt_topic_prefix => "bmw-$account_id",
    };

    unless (-d $account_dir) {
        make_path($account_dir);
    }

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
    my $pid_file = "$account_dir/bridge.pid";
    my $status = {
        running => 0,
        pid => undef,
    };

    if (-f $pid_file) {
        open(my $fh, '<', $pid_file);
        my $pid = <$fh>;
        close($fh);

        chomp($pid);

        # On Windows, we can't use kill(0, $pid) to check if process is running
        # Just assume it's not running in dev mode
        $status->{running} = 0;
        $status->{pid} = $pid;
    }

    return $status;
}

sub load_device_code {
    my $device_file = "$account_dir/device_code.json";
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
