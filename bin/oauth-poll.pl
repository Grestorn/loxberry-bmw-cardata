#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use Time::HiRes qw(sleep);
use File::Basename;

# BMW CarData API Configuration
use constant {
    API_BASE_URL => 'https://customer.bmwgroup.com',
    TOKEN_ENDPOINT => '/gcdm/oauth/token',
    CARDATA_API_BASE_URL => 'https://api-cardata.bmwgroup.com',
    VEHICLES_MAPPINGS_ENDPOINT => '/customers/vehicles/mappings',
};

# Plugin data directory
my $script_dir = dirname(__FILE__);
my $plugin_dir = dirname($script_dir);
my $data_dir = "$plugin_dir/data";

my $config_file = "$data_dir/config.json";
my $pkce_file = "$data_dir/pkce.json";
my $device_file = "$data_dir/device_code.json";
my $tokens_file = "$data_dir/tokens.json";

# Load configuration
unless (-f $config_file) {
    die "ERROR: Configuration file not found: $config_file\n" .
        "Please configure the plugin via web interface first.\n";
}

my $config = load_json($config_file);
unless ($config->{client_id} && $config->{client_id} ne '') {
    die "ERROR: CLIENT_ID not configured.\n" .
        "Please set your BMW CarData Client ID in the web interface.\n";
}

my $CLIENT_ID = $config->{client_id};

print "=== BMW CarData OAuth Token Polling ===\n\n";

# Load PKCE data
unless (-f $pkce_file) {
    die "PKCE data not found. Please run oauth-init.pl first.\n";
}
my $pkce_data = load_json($pkce_file);
my $code_verifier = $pkce_data->{code_verifier};
print "✓ Loaded PKCE data\n";

# Load device code data
unless (-f $device_file) {
    die "Device code data not found. Please run oauth-init.pl first.\n";
}
my $device_data = load_json($device_file);
my $device_code = $device_data->{device_code};
my $interval = $device_data->{interval} || 5;
my $expires_in = $device_data->{expires_in} || 300;
print "✓ Loaded device code data\n";
print "  Polling interval: $interval seconds\n";
print "  Code expires in: $expires_in seconds\n\n";

# Calculate deadline
my $start_time = time();
my $deadline = $start_time + $expires_in;

print "Starting token polling...\n";
print "Please complete authorization in your browser if not done yet.\n\n";

my $attempt = 0;
my $max_attempts = int($expires_in / $interval) + 5;

while (time() < $deadline && $attempt < $max_attempts) {
    $attempt++;
    print "Attempt $attempt: Polling for tokens...\n";

    my $token_response = poll_for_token($device_code, $code_verifier);

    if ($token_response && ref($token_response) eq 'HASH') {
        # Check if we got tokens
        if (exists $token_response->{access_token}) {
            print "\n✓ SUCCESS! Tokens received!\n\n";

            # Add metadata
            my $now = time();
            $token_response->{retrieved_at} = $now;
            $token_response->{expires_at} = $now + ($token_response->{expires_in} || 3600);

            # Calculate refresh token expiry (2 weeks = 1209600 seconds)
            $token_response->{refresh_expires_at} = $now + 1209600;

            # Save tokens
            save_json($tokens_file, $token_response);
            print "✓ Tokens saved to $tokens_file\n\n";

            # Display token information
            print "=== Token Information ===\n";
            print "Access Token (GCDM - for manual API testing):\n";
            print "$token_response->{access_token}\n\n";
            print "ID Token:      " . substr($token_response->{id_token}, 0, 20) . "...\n";
            print "Refresh Token: " . substr($token_response->{refresh_token}, 0, 20) . "...\n";
            print "GCID:          $token_response->{gcid}\n" if exists $token_response->{gcid};
            print "Scope:         $token_response->{scope}\n" if exists $token_response->{scope};
            print "Expires in:    $token_response->{expires_in} seconds\n";

            my $expires_at_str = localtime($token_response->{expires_at});
            my $refresh_expires_str = localtime($token_response->{refresh_expires_at});
            print "Expires at:    $expires_at_str\n";
            print "Refresh until: $refresh_expires_str\n\n";

            # Retrieve vehicle mappings
            print "=== Retrieving Vehicle Mappings ===\n";
            my $mappings = get_vehicle_mappings($token_response->{access_token});
            if ($mappings) {
                print "✓ Vehicle mappings retrieved successfully\n\n";
                print "Full mapping response:\n";
                print JSON->new->pretty->encode($mappings);
                print "\n";
            } else {
                print "✗ Failed to retrieve vehicle mappings\n\n";
            }

            # Cleanup temporary files
            unlink($pkce_file);
            unlink($device_file);
            print "✓ Cleaned up temporary files\n\n";

            print "=== Next Steps ===\n";
            print "1. Configure your VIN and stream settings in the web interface\n";
            print "2. Start the BMW CarData bridge daemon\n";
            print "3. Tokens will be automatically refreshed by cron job\n\n";

            exit 0;
        }

        # Handle specific error codes
        if (exists $token_response->{error}) {
            my $error = $token_response->{error};

            if ($error eq 'authorization_pending') {
                print "  → Authorization pending. Waiting for user approval...\n";
            } elsif ($error eq 'slow_down') {
                print "  → Slow down requested. Increasing interval...\n";
                $interval += 5;
            } elsif ($error eq 'expired_token') {
                die "\n✗ ERROR: Device code has expired. Please run oauth-init.pl again.\n";
            } elsif ($error eq 'access_denied') {
                die "\n✗ ERROR: Authorization was denied by user.\n";
            } else {
                print "  → Error: $error\n";
                if (exists $token_response->{error_description}) {
                    print "  → Description: $token_response->{error_description}\n";
                }
            }
        }
    }

    # Wait before next attempt
    if ($attempt < $max_attempts && time() < $deadline) {
        sleep($interval);
    }
}

# If we get here, polling timed out
print "\n✗ ERROR: Polling timed out. Authorization not completed in time.\n";
print "Please run oauth-init.pl again to start a new authorization flow.\n\n";
exit 1;

#
# Subroutines
#

# Poll for token using device code
sub poll_for_token {
    my ($device_code, $code_verifier) = @_;

    my $ua = LWP::UserAgent->new(
        agent => 'LoxBerry-BMW-CarData/0.0.1',
        timeout => 30,
    );

    my $url = API_BASE_URL . TOKEN_ENDPOINT;

    my $response = $ua->post($url, {
        client_id => CLIENT_ID,
        device_code => $device_code,
        grant_type => 'urn:ietf:params:oauth:grant-type:device_code',
        code_verifier => $code_verifier,
    });

    # Parse response
    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        warn "  JSON decode error: $@\n";
        return undef;
    }

    return $data;
}

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

    open(my $fh, '>', $filename) or die "Cannot write to $filename: $!\n";
    print $fh encode_json($data);
    close($fh);
}

# Get vehicle mappings from BMW CarData API
sub get_vehicle_mappings {
    my ($access_token) = @_;

    print "Fetching vehicle mappings from BMW CarData API...\n";

    my $ua = LWP::UserAgent->new(
        agent => 'LoxBerry-BMW-CarData/0.0.1',
        timeout => 30,
    );

    my $url = CARDATA_API_BASE_URL . VEHICLES_MAPPINGS_ENDPOINT;

    my $response = $ua->get($url,
        'Authorization' => "Bearer $access_token",
        'x-version' => 'v1',
        'Accept' => 'application/json',
    );

    unless ($response->is_success) {
        warn "HTTP Error: " . $response->status_line . "\n";
        warn "Response: " . $response->decoded_content . "\n";
        return undef;
    }

    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        warn "JSON decode error: $@\n";
        warn "Response: " . $response->decoded_content . "\n";
        return undef;
    }

    return $data;
}
