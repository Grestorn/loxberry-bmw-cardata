#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use File::Basename;
use Getopt::Long;
use LoxBerry::Log;

# BMW CarData API Configuration
use constant {
    API_BASE_URL => 'https://customer.bmwgroup.com',
    TOKEN_ENDPOINT => '/gcdm/oauth/token',
    REFRESH_MARGIN => 300,  # Refresh tokens 5 minutes before expiry
};

# Plugin data directory
my $data_dir = "REPLACELBPDATADIR";
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
my $force = 0;

GetOptions(
    'force|f' => \$force,
) or die "Usage: $0 [check|refresh|status] [--force]\n";

# Initialize logging
my $log = LoxBerry::Log->new(
    name => 'token-manager',
    stderr => 1,  # Redirect STDERR to log
    addtime => 1  # Add timestamps to log entries
);

# Main logic
if ($command eq 'check') {
    exit check_and_refresh();
} elsif ($command eq 'refresh') {
    exit refresh_tokens($force);
} elsif ($command eq 'status') {
    exit show_status();
} else {
    die "Unknown command: $command\nUsage: $0 [check|refresh|status] [--force]\n";
}

#
# Commands
#

# Check if tokens need refresh and refresh if necessary
sub check_and_refresh {
    LOGSTART("BMW Token Check");
    LOGINF("Checking token status...");

    unless (-f $tokens_file) {
        LOGERR("No tokens found. Please run oauth-init.pl and oauth-poll.pl first.");
        LOGEND;
        return 1;
    }

    my $tokens = load_json($tokens_file);
    my $now = time();

    # Check if refresh token is expired
    if (exists $tokens->{refresh_expires_at} && $tokens->{refresh_expires_at} < $now) {
        LOGCRIT("Refresh token has expired. Please re-authenticate using oauth-init.pl.");
        LOGEND;
        return 1;
    }

    # Check if access/id tokens need refresh
    my $expires_at = $tokens->{expires_at} || 0;
    my $needs_refresh = ($expires_at - $now) < REFRESH_MARGIN;

    if ($needs_refresh || $force) {
        LOGINF("Tokens need refresh. Refreshing now...");
        my $result = refresh_tokens($force);
        LOGEND;
        return $result;
    } else {
        my $time_left = $expires_at - $now;
        my $minutes_left = int($time_left / 60);
        LOGOK("Tokens are valid. Expires in $minutes_left minutes.");
        LOGEND;
        return 0;
    }
}

# Refresh access and ID tokens using refresh token
sub refresh_tokens {
    my ($force_refresh) = @_;

    LOGSTART("BMW Token Refresh") unless $force_refresh;  # Don't double-start if called from check_and_refresh
    LOGINF("Starting token refresh...");

    unless (-f $tokens_file) {
        LOGERR("No tokens found. Please run oauth-init.pl and oauth-poll.pl first.");
        LOGEND unless $force_refresh;
        return 1;
    }

    my $old_tokens = load_json($tokens_file);

    unless (exists $old_tokens->{refresh_token}) {
        LOGERR("No refresh token found in tokens file.");
        LOGEND unless $force_refresh;
        return 1;
    }

    my $refresh_token = $old_tokens->{refresh_token};

    # Check if refresh token is still valid
    my $now = time();
    if (exists $old_tokens->{refresh_expires_at} && $old_tokens->{refresh_expires_at} < $now) {
        LOGCRIT("Refresh token has expired. Please re-authenticate using oauth-init.pl.");
        LOGEND unless $force_refresh;
        return 1;
    }

    # Check if we really need to refresh (unless forced)
    unless ($force_refresh) {
        my $expires_at = $old_tokens->{expires_at} || 0;
        my $time_left = $expires_at - $now;

        if ($time_left > REFRESH_MARGIN) {
            my $minutes_left = int($time_left / 60);
            LOGINF("Tokens are still valid for $minutes_left minutes. Use --force to refresh anyway.");
            LOGEND unless $force_refresh;
            return 0;
        }
    }

    # Call BMW CarData API to refresh tokens
    LOGINF("Requesting new tokens from BMW CarData API...");
    my $new_tokens = request_token_refresh($refresh_token);

    unless ($new_tokens) {
        LOGERR("Failed to refresh tokens. API request failed.");
        LOGEND unless $force_refresh;
        return 1;
    }

    # Check for errors
    if (exists $new_tokens->{error}) {
        LOGERR("Token refresh failed: $new_tokens->{error}");
        if (exists $new_tokens->{error_description}) {
            LOGERR("Description: $new_tokens->{error_description}");
        }
        LOGEND unless $force_refresh;
        return 1;
    }

    # Verify we got new tokens
    unless (exists $new_tokens->{access_token} && exists $new_tokens->{id_token} && exists $new_tokens->{refresh_token}) {
        LOGERR("Invalid response from API. Missing required tokens.");
        LOGEND unless $force_refresh;
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
    LOGOK("Tokens refreshed successfully.");

    my $expires_at_str = localtime($new_tokens->{expires_at});
    my $refresh_expires_str = localtime($new_tokens->{refresh_expires_at});
    LOGDEB("New tokens expire at: $expires_at_str");
    LOGDEB("Refresh token valid until: $refresh_expires_str");

    LOGEND unless $force_refresh;
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
        client_id => $CLIENT_ID,
    });

    unless ($response->is_success) {
        LOGERR("HTTP Error: " . $response->status_line);
        LOGDEB("Response: " . $response->decoded_content);
        return undef;
    }

    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        LOGERR("JSON decode error: $@");
        LOGDEB("Response: " . $response->decoded_content);
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