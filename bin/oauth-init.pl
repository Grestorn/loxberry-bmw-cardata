#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use MIME::Base64 qw(encode_base64url);
use Digest::SHA qw(sha256);
use File::Path qw(make_path);
use File::Basename;
use LoxBerry::Log;

# BMW CarData API Configuration
use constant {
    API_BASE_URL => 'https://customer.bmwgroup.com',
    DEVICE_CODE_ENDPOINT => '/gcdm/oauth/device/code',
    TOKEN_ENDPOINT => '/gcdm/oauth/token',
    SCOPES => 'authenticate_user openid cardata:api:read cardata:streaming:read',
};

# Plugin data directory
my $data_dir = "REPLACELBPDATADIR";
my $config_file = "$data_dir/config.json";

# Ensure data directory exists
unless (-d $data_dir) {
    make_path($data_dir) or die "Cannot create data directory $data_dir: $!\n";
}

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
    name => 'oauth-init',
    stderr => 1,  # Redirect STDERR to log
    addtime => 1  # Add timestamps to log entries
);
LOGSTART("BMW CarData OAuth Init");
LOGDEB("=== BMW CarData OAuth Initialization ===");

# Step 1: Generate PKCE code_verifier and code_challenge
LOGINF("Step 1: Generating PKCE parameters...");
my $code_verifier = generate_code_verifier();
my $code_challenge = generate_code_challenge($code_verifier);
LOGOK("Code verifier generated");
LOGOK("Code challenge generated (SHA256)");

# Save code_verifier for later use
my $pkce_file = "$data_dir/pkce.json";
save_json($pkce_file, { code_verifier => $code_verifier });
LOGOK("PKCE data saved to $pkce_file");

# Step 2: Request device code
LOGINF("Step 2: Requesting device code from BMW CarData...");
my $device_response = request_device_code($code_challenge);

unless ($device_response) {
    LOGCRIT("Failed to request device code. Please check your CLIENT_ID and network connection.");
    LOGEND;
    die "Failed to request device code.\n";
}

LOGOK("Device code received successfully");

# Display response details
LOGDEB("=== Device Authorization Response ===");
LOGDEB("User Code:          $device_response->{user_code}");
LOGDEB("Device Code:        $device_response->{device_code}");
LOGDEB("Verification URI:   $device_response->{verification_uri}");
LOGDEB("Expires in:         $device_response->{expires_in} seconds");
LOGDEB("Polling interval:   $device_response->{interval} seconds");

# Save device response for token polling
my $device_file = "$data_dir/device_code.json";
save_json($device_file, $device_response);
LOGOK("Device code data saved to $device_file");

# Step 3: Display verification URI (do NOT open browser automatically)
LOGINF("=== Authorization Required ===");

LOGEND;

exit 0;

#
# Subroutines
#

# Generate cryptographically random code_verifier (RFC 7636 Section 4.1)
# Minimum 43 characters, maximum 128 characters
sub generate_code_verifier {
    my $length = 128;  # Use maximum length for better security
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~');
    my $verifier = '';

    # Use /dev/urandom for cryptographic randomness
    open(my $fh, '<', '/dev/urandom') or die "Cannot open /dev/urandom: $!\n";
    for (1..$length) {
        my $byte;
        read($fh, $byte, 1);
        $verifier .= $chars[ord($byte) % scalar(@chars)];
    }
    close($fh);

    return $verifier;
}

# Generate code_challenge from code_verifier (RFC 7636 Section 4.2)
# Using S256 method: BASE64URL(SHA256(ASCII(code_verifier)))
sub generate_code_challenge {
    my ($verifier) = @_;

    # Calculate SHA256 hash
    my $hash = sha256($verifier);

    # Encode as base64url (no padding)
    my $challenge = encode_base64url($hash);

    # Remove any padding that might have been added
    $challenge =~ s/=+$//;

    return $challenge;
}

# Request device code from BMW CarData API
sub request_device_code {
    my ($code_challenge) = @_;

    my $ua = LWP::UserAgent->new(
        agent => 'LoxBerry-BMW-CarData/0.0.1',
        timeout => 30,
    );

    my $url = API_BASE_URL . DEVICE_CODE_ENDPOINT;

    my $response = $ua->post($url, {
        client_id => $CLIENT_ID,
        response_type => 'device_code',
        scope => SCOPES,
        code_challenge => $code_challenge,
        code_challenge_method => 'S256',
    });

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