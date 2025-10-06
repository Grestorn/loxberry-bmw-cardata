#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use MIME::Base64 qw(encode_base64url);
use Digest::SHA qw(sha256);
use File::Path qw(make_path);
use File::Basename;

# BMW CarData API Configuration
use constant {
    CLIENT_ID => 'YOUR_CLIENT_ID_HERE',  # Replace with your Client ID from BMW CarData Portal
    API_BASE_URL => 'https://customer.bmwgroup.com',
    DEVICE_CODE_ENDPOINT => '/gcdm/oauth/device/code',
    TOKEN_ENDPOINT => '/gcdm/oauth/token',
    SCOPES => 'authenticate_user openid cardata:api:read cardata:streaming:read',
};

# Plugin data directory
my $script_dir = dirname(__FILE__);
my $plugin_dir = dirname($script_dir);
my $data_dir = "$plugin_dir/data";

# Ensure data directory exists
unless (-d $data_dir) {
    make_path($data_dir) or die "Cannot create data directory $data_dir: $!\n";
}

print "=== BMW CarData OAuth Initialization ===\n\n";

# Step 1: Generate PKCE code_verifier and code_challenge
print "Step 1: Generating PKCE parameters...\n";
my $code_verifier = generate_code_verifier();
my $code_challenge = generate_code_challenge($code_verifier);
print "  ✓ Code verifier generated\n";
print "  ✓ Code challenge generated (SHA256)\n\n";

# Save code_verifier for later use
my $pkce_file = "$data_dir/pkce.json";
save_json($pkce_file, { code_verifier => $code_verifier });
print "  ✓ PKCE data saved to $pkce_file\n\n";

# Step 2: Request device code
print "Step 2: Requesting device code from BMW CarData...\n";
my $device_response = request_device_code($code_challenge);

unless ($device_response) {
    die "Failed to request device code. Please check your CLIENT_ID and network connection.\n";
}

print "  ✓ Device code received successfully\n\n";

# Display response details
print "=== Device Authorization Response ===\n";
print "User Code:          $device_response->{user_code}\n";
print "Device Code:        $device_response->{device_code}\n";
print "Verification URI:   $device_response->{verification_uri}\n";
print "Expires in:         $device_response->{expires_in} seconds\n";
print "Polling interval:   $device_response->{interval} seconds\n\n";

# Save device response for token polling
my $device_file = "$data_dir/device_code.json";
save_json($device_file, $device_response);
print "  ✓ Device code data saved to $device_file\n\n";

# Step 3: Display verification URI (do NOT open browser automatically)
print "=== Authorization Required ===\n";
if (exists $device_response->{verification_uri_complete}) {
    print "Verification URL (with pre-filled code):\n";
    print "  $device_response->{verification_uri_complete}\n\n";
} else {
    print "Verification URL:\n";
    print "  $device_response->{verification_uri}\n\n";
    print "User Code (enter in browser):\n";
    print "  $device_response->{user_code}\n\n";
}

print "=== Next Steps ===\n";
print "1. Click the verification link shown in the web interface\n";
print "2. Log in with your BMW ID credentials\n";
print "3. Approve the authorization request\n";
print "4. Return to web interface and click 'Retrieve Tokens'\n\n";

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
        client_id => CLIENT_ID,
        response_type => 'device_code',
        scope => SCOPES,
        code_challenge => $code_challenge,
        code_challenge_method => 'S256',
    });

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

# Save data as JSON file
sub save_json {
    my ($filename, $data) = @_;

    open(my $fh, '>', $filename) or die "Cannot write to $filename: $!\n";
    print $fh encode_json($data);
    close($fh);
}