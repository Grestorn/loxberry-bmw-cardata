#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use Time::HiRes qw(sleep);
use File::Basename;
use LoxBerry::Log;

# BMW CarData API Configuration
use constant {
    API_BASE_URL => 'https://customer.bmwgroup.com',
    TOKEN_ENDPOINT => '/gcdm/oauth/token',
    CARDATA_API_BASE_URL => 'https://api-cardata.bmwgroup.com',
    VEHICLES_MAPPINGS_ENDPOINT => '/customers/vehicles/mappings',
};

# Plugin data directory
my $data_dir = "REPLACELBPDATADIR";

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

# Initialize logging
my $log = LoxBerry::Log->new(
    name => 'oauth-poll',
    stderr => 1,  # Redirect STDERR to log
    addtime => 1  # Add timestamps to log entries
);
LOGSTART("BMW CarData OAuth Poll");
LOGDEB("=== BMW CarData OAuth Token Polling ===");

# Load PKCE data
unless (-f $pkce_file) {
    LOGCRIT("PKCE data not found. Please run oauth-init.pl first.");
    LOGEND;
    die "PKCE data not found.\n";
}
my $pkce_data = load_json($pkce_file);
my $code_verifier = $pkce_data->{code_verifier};
LOGOK("Loaded PKCE data");

# Load device code data
unless (-f $device_file) {
    LOGCRIT("Device code data not found. Please run oauth-init.pl first.");
    LOGEND;
    die "Device code data not found.\n";
}
my $device_data = load_json($device_file);
my $device_code = $device_data->{device_code};
my $interval = $device_data->{interval} || 5;
my $expires_in = $device_data->{expires_in} || 300;
LOGOK("Loaded device code data");
LOGDEB("Polling interval: $interval seconds");
LOGDEB("Code expires in: $expires_in seconds");

# Calculate deadline
my $start_time = time();
my $deadline = $start_time + $expires_in;

LOGINF("Starting token polling...");
LOGINF("Please complete authorization in your browser if not done yet.");

my $attempt = 0;
my $max_attempts = int($expires_in / $interval) + 5;

while (time() < $deadline && $attempt < $max_attempts) {
    $attempt++;
    LOGDEB("Attempt $attempt: Polling for tokens...");

    my $token_response = poll_for_token($device_code, $code_verifier);

    if ($token_response && ref($token_response) eq 'HASH') {
        # Check if we got tokens
        if (exists $token_response->{access_token}) {
            LOGOK("SUCCESS! Tokens received!");

            # Add metadata
            my $now = time();
            $token_response->{retrieved_at} = $now;
            $token_response->{expires_at} = $now + ($token_response->{expires_in} || 3600);

            # Calculate refresh token expiry (2 weeks = 1209600 seconds)
            $token_response->{refresh_expires_at} = $now + 1209600;

            # Save tokens
            save_json($tokens_file, $token_response);
            LOGOK("Tokens saved to $tokens_file");

            # Display token information
            LOGDEB("=== Token Information ===");
            print "Access Token (GCDM - for manual API testing):\n";
            print "$token_response->{access_token}\n\n";
            LOGDEB("ID Token:      " . substr($token_response->{id_token}, 0, 20) . "...");
            LOGDEB("Refresh Token: " . substr($token_response->{refresh_token}, 0, 20) . "...");
            LOGDEB("GCID:          $token_response->{gcid}") if exists $token_response->{gcid};
            LOGDEB("Scope:         $token_response->{scope}") if exists $token_response->{scope};
            LOGDEB("Expires in:    $token_response->{expires_in} seconds");

            my $expires_at_str = localtime($token_response->{expires_at});
            my $refresh_expires_str = localtime($token_response->{refresh_expires_at});
            LOGDEB("Expires at:    $expires_at_str");
            LOGDEB("Refresh until: $refresh_expires_str");

            # Retrieve vehicle mappings
            LOGINF("=== Retrieving Vehicle Mappings ===");
            my $mappings = get_vehicle_mappings($token_response->{access_token});
            if ($mappings) {
                LOGOK("Vehicle mappings retrieved successfully");
                LOGDEB("Full mapping response:");
                LOGDEB(JSON->new->pretty->encode($mappings));

                # Extract VINs and save to config if not already configured
                my @vins = extract_vins_from_mappings($mappings);
                if (@vins > 0) {
                    LOGINF("Found VINs: " . join(", ", @vins));

                    # Check if config exists and if VINs are already configured
                    if (-f $config_file) {
                        my $existing_config = load_json($config_file);
                        if (!$existing_config->{vins} || @{$existing_config->{vins}} == 0) {
                            # Auto-fill VINs in config
                            $existing_config->{vins} = \@vins;
                            save_json($config_file, $existing_config);
                            LOGOK("VINs automatically added to configuration");
                        } else {
                            LOGINF("VINs already configured, skipping auto-fill");
                        }
                    }
                }
            } else {
                LOGWARN("Failed to retrieve vehicle mappings");
            }

            # Cleanup temporary files
            unlink($pkce_file);
            unlink($device_file);
            LOGOK("Cleaned up temporary files");

            print "\n=== Next Steps ===\n";
            print "1. Configure your VIN and stream settings in the web interface\n";
            print "2. Start the BMW CarData bridge daemon\n";
            print "3. Tokens will be automatically refreshed by cron job\n\n";

            LOGEND;
            exit 0;
        }

        # Handle specific error codes
        if (exists $token_response->{error}) {
            my $error = $token_response->{error};

            if ($error eq 'authorization_pending') {
                LOGDEB("Authorization pending. Waiting for user approval...");
            } elsif ($error eq 'slow_down') {
                LOGWARN("Slow down requested. Increasing interval...");
                $interval += 5;
            } elsif ($error eq 'expired_token') {
                LOGCRIT("Device code has expired. Please run oauth-init.pl again.");
                LOGEND;
                die "Device code has expired.\n";
            } elsif ($error eq 'access_denied') {
                LOGCRIT("Authorization was denied by user.");
                LOGEND;
                die "Authorization was denied.\n";
            } else {
                LOGERR("Error: $error");
                if (exists $token_response->{error_description}) {
                    LOGERR("Description: $token_response->{error_description}");
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
LOGCRIT("Polling timed out. Authorization not completed in time.");
print "Please run oauth-init.pl again to start a new authorization flow.\n\n";
LOGEND;
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
        client_id => $CLIENT_ID,
        device_code => $device_code,
        grant_type => 'urn:ietf:params:oauth:grant-type:device_code',
        code_verifier => $code_verifier,
    });

    # Parse response
    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        LOGERR("JSON decode error: $@");
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
    print $fh JSON->new->pretty->encode($data);
    close($fh);

    # Set appropriate permissions
    chmod(0600, $filename);
}

# Extract VINs from vehicle mappings response
sub extract_vins_from_mappings {
    my ($mappings) = @_;
    my @vins;

    # The response can be either:
    # 1. A single VehicleMappingDto object
    # 2. An array of VehicleMappingDto objects

    if (ref($mappings) eq 'HASH') {
        # Single object
        if (exists $mappings->{vin} && $mappings->{vin}) {
            push @vins, $mappings->{vin};
        }
    } elsif (ref($mappings) eq 'ARRAY') {
        # Array of objects
        foreach my $mapping (@$mappings) {
            if (ref($mapping) eq 'HASH' && exists $mapping->{vin} && $mapping->{vin}) {
                push @vins, $mapping->{vin};
            }
        }
    }

    return @vins;
}

# Get vehicle mappings from BMW CarData API
sub get_vehicle_mappings {
    my ($access_token) = @_;

    LOGDEB("Fetching vehicle mappings from BMW CarData API...");

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
        LOGERR("HTTP Error: " . $response->status_line);
        LOGERR("Response: " . $response->decoded_content);
        return undef;
    }

    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        LOGERR("JSON decode error: $@");
        LOGERR("Response: " . $response->decoded_content);
        return undef;
    }

    return $data;
}