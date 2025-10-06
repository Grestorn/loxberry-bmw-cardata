#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use File::Basename;
use Getopt::Long;

# BMW CarData API Configuration
use constant {
    API_BASE_URL => 'https://customer.bmwgroup.com',
    TOKEN_ENDPOINT => '/gcdm/oauth/token',
    REFRESH_MARGIN => 300,  # Refresh tokens 5 minutes before expiry
};

# Plugin data directory
my $script_dir = dirname(__FILE__);
my $plugin_dir = dirname($script_dir);
my $data_dir = "$plugin_dir/data";
my $config_file = "$data_dir/config.json";
my $tokens_file = "$data_dir/tokens.json";

# Load configuration
my $CLIENT_ID;
if (-f $config_file) {
    my $config = load_json($config_file);
    $CLIENT_ID = $config->{client_id} if $config && $config->{client_id};
}

# Command line options
my $command = $ARGV[0] || 'check';
my $verbose = 0;
my $force = 0;

GetOptions(
    'verbose|v' => \$verbose,
    'force|f' => \$force,
) or die "Usage: $0 [check|refresh|status] [--verbose] [--force]\n";

# Main logic
if ($command eq 'check') {
    exit check_and_refresh();
} elsif ($command eq 'refresh') {
    exit refresh_tokens($force);
} elsif ($command eq 'status') {
    exit show_status();
} else {
    die "Unknown command: $command\nUsage: $0 [check|refresh|status] [--verbose] [--force]\n";
}

#
# Commands
#

# Check if tokens need refresh and refresh if necessary
sub check_and_refresh {
    log_message("Checking token status...");

    unless (-f $tokens_file) {
        log_message("ERROR: No tokens found. Please run oauth-init.pl and oauth-poll.pl first.");
        return 1;
    }

    my $tokens = load_json($tokens_file);
    my $now = time();

    # Check if refresh token is expired
    if (exists $tokens->{refresh_expires_at} && $tokens->{refresh_expires_at} < $now) {
        log_message("ERROR: Refresh token has expired. Please re-authenticate using oauth-init.pl.");
        return 1;
    }

    # Check if access/id tokens need refresh
    my $expires_at = $tokens->{expires_at} || 0;
    my $needs_refresh = ($expires_at - $now) < REFRESH_MARGIN;

    if ($needs_refresh || $force) {
        log_message("Tokens need refresh. Refreshing now...");
        return refresh_tokens($force);
    } else {
        my $time_left = $expires_at - $now;
        my $minutes_left = int($time_left / 60);
        log_message("Tokens are valid. Expires in $minutes_left minutes.");
        return 0;
    }
}

# Refresh access and ID tokens using refresh token
sub refresh_tokens {
    my ($force_refresh) = @_;

    log_message("Starting token refresh...");

    unless (-f $tokens_file) {
        log_message("ERROR: No tokens found. Please run oauth-init.pl and oauth-poll.pl first.");
        return 1;
    }

    my $old_tokens = load_json($tokens_file);

    unless (exists $old_tokens->{refresh_token}) {
        log_message("ERROR: No refresh token found in tokens file.");
        return 1;
    }

    my $refresh_token = $old_tokens->{refresh_token};

    # Check if refresh token is still valid
    my $now = time();
    if (exists $old_tokens->{refresh_expires_at} && $old_tokens->{refresh_expires_at} < $now) {
        log_message("ERROR: Refresh token has expired. Please re-authenticate using oauth-init.pl.");
        return 1;
    }

    # Check if we really need to refresh (unless forced)
    unless ($force_refresh) {
        my $expires_at = $old_tokens->{expires_at} || 0;
        my $time_left = $expires_at - $now;

        if ($time_left > REFRESH_MARGIN) {
            my $minutes_left = int($time_left / 60);
            log_message("Tokens are still valid for $minutes_left minutes. Use --force to refresh anyway.");
            return 0;
        }
    }

    # Call BMW CarData API to refresh tokens
    log_message("Requesting new tokens from BMW CarData API...");
    my $new_tokens = request_token_refresh($refresh_token);

    unless ($new_tokens) {
        log_message("ERROR: Failed to refresh tokens. API request failed.");
        return 1;
    }

    # Check for errors
    if (exists $new_tokens->{error}) {
        log_message("ERROR: Token refresh failed: $new_tokens->{error}");
        if (exists $new_tokens->{error_description}) {
            log_message("  Description: $new_tokens->{error_description}");
        }
        return 1;
    }

    # Verify we got new tokens
    unless (exists $new_tokens->{access_token} && exists $new_tokens->{id_token} && exists $new_tokens->{refresh_token}) {
        log_message("ERROR: Invalid response from API. Missing required tokens.");
        return 1;
    }

    # Add metadata
    $new_tokens->{retrieved_at} = $now;
    $new_tokens->{expires_at} = $now + ($new_tokens->{expires_in} || 3600);
    $new_tokens->{refresh_expires_at} = $now + 1209600;  # 2 weeks

    # Preserve GCID if not in response
    if (!exists $new_tokens->{gcid} && exists $old_tokens->{gcid}) {
        $new_tokens->{gcid} = $old_tokens->{gcid};
    }

    # Save new tokens
    save_json($tokens_file, $new_tokens);
    log_message("SUCCESS: Tokens refreshed successfully.");

    if ($verbose) {
        my $expires_at_str = localtime($new_tokens->{expires_at});
        my $refresh_expires_str = localtime($new_tokens->{refresh_expires_at});
        log_message("  New tokens expire at: $expires_at_str");
        log_message("  Refresh token valid until: $refresh_expires_str");
    }

    return 0;
}

# Show current token status
sub show_status {
    unless (-f $tokens_file) {
        print "Status: NO TOKENS\n";
        print "Please run oauth-init.pl and oauth-poll.pl to authenticate.\n";
        return 1;
    }

    my $tokens = load_json($tokens_file);
    my $now = time();

    print "=== BMW CarData Token Status ===\n\n";

    # Access/ID Token status
    if (exists $tokens->{expires_at}) {
        my $expires_at = $tokens->{expires_at};
        my $time_left = $expires_at - $now;

        print "Access/ID Tokens:\n";
        if ($time_left > 0) {
            my $minutes_left = int($time_left / 60);
            my $seconds_left = $time_left % 60;
            print "  Status: VALID\n";
            print "  Expires in: ${minutes_left}m ${seconds_left}s\n";
            print "  Expires at: " . localtime($expires_at) . "\n";

            if ($time_left < REFRESH_MARGIN) {
                print "  ⚠ WARNING: Tokens will expire soon!\n";
            }
        } else {
            print "  Status: EXPIRED\n";
            print "  Expired: " . abs(int($time_left / 60)) . " minutes ago\n";
        }
    } else {
        print "Access/ID Tokens: UNKNOWN\n";
    }

    print "\n";

    # Refresh Token status
    if (exists $tokens->{refresh_expires_at}) {
        my $refresh_expires_at = $tokens->{refresh_expires_at};
        my $time_left = $refresh_expires_at - $now;

        print "Refresh Token:\n";
        if ($time_left > 0) {
            my $days_left = int($time_left / 86400);
            my $hours_left = int(($time_left % 86400) / 3600);
            print "  Status: VALID\n";
            print "  Expires in: ${days_left}d ${hours_left}h\n";
            print "  Expires at: " . localtime($refresh_expires_at) . "\n";

            if ($days_left < 2) {
                print "  ⚠ WARNING: Refresh token will expire soon! Re-authenticate required.\n";
            }
        } else {
            print "  Status: EXPIRED\n";
            print "  ⚠ ERROR: Re-authentication required!\n";
            print "  Run: oauth-init.pl and oauth-poll.pl\n";
        }
    } else {
        print "Refresh Token: UNKNOWN\n";
    }

    print "\n";

    # Additional info
    if (exists $tokens->{gcid}) {
        print "User GCID: $tokens->{gcid}\n";
    }

    if (exists $tokens->{scope}) {
        print "Scopes: $tokens->{scope}\n";
    }

    print "\n";

    return 0;
}

#
# API Functions
#

# Request token refresh from BMW CarData API
sub request_token_refresh {
    my ($refresh_token) = @_;

    my $ua = LWP::UserAgent->new(
        agent => 'LoxBerry-BMW-CarData/0.0.1',
        timeout => 30,
    );

    my $url = API_BASE_URL . TOKEN_ENDPOINT;

    my $response = $ua->post($url, {
        grant_type => 'refresh_token',
        refresh_token => $refresh_token,
        client_id => CLIENT_ID,
    });

    unless ($response->is_success) {
        log_message("HTTP Error: " . $response->status_line);
        if ($verbose) {
            log_message("Response: " . $response->decoded_content);
        }
        return undef;
    }

    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        log_message("JSON decode error: $@");
        if ($verbose) {
            log_message("Response: " . $response->decoded_content);
        }
        return undef;
    }

    return $data;
}

#
# Utility Functions
#

# Load JSON file
sub load_json {
    my ($filename) = @_;

    open(my $fh, '<', $filename) or die "Cannot read $filename: $!\n";
    my $content = do { local $/; <$fh> };
    close($fh);

    return decode_json($content);
}

# Save data as JSON file
sub save_json {
    my ($filename, $data) = @_;

    # Create backup of old file
    if (-f $filename) {
        my $backup = "$filename.bak";
        rename($filename, $backup);
    }

    open(my $fh, '>', $filename) or die "Cannot write to $filename: $!\n";
    print $fh JSON->new->pretty->encode($data);
    close($fh);

    # Set appropriate permissions
    chmod(0600, $filename);
}

# Log message with timestamp
sub log_message {
    my ($message) = @_;
    my $timestamp = localtime();
    print "[$timestamp] $message\n";
}
