#!/usr/bin/env perl

# Local Development HTTP Server for BMW CarData Plugin
# Starts a simple HTTP server with CGI support on port 8080

use strict;
use warnings;
use HTTP::Server::Simple::CGI;
use FindBin qw($RealBin);

# Change to project root
chdir("$RealBin/..");

{
    package MyWebServer;
    use base qw(HTTP::Server::Simple::CGI);

    sub handle_request {
        my ($self, $cgi) = @_;

        my $path = $cgi->path_info();

        # Default to index-dev.cgi
        if ($path eq '/' || $path eq '') {
            $path = '/dev/index-dev.cgi';
        }

        # Serve the CGI script
        if ($path =~ /\.cgi$/) {
            my $script = "$RealBin/../$path";
            $script =~ s{/+}{/}g; # Normalize slashes

            if (-f $script) {
                # Execute the CGI script
                local $ENV{GATEWAY_INTERFACE} = 'CGI/1.1';
                local $ENV{REQUEST_METHOD} = $cgi->request_method();
                local $ENV{QUERY_STRING} = $cgi->query_string();
                local $ENV{CONTENT_TYPE} = $cgi->content_type();
                local $ENV{CONTENT_LENGTH} = $cgi->content_length() || 0;

                # Execute the script and capture output
                open(my $fh, '-|', "perl", $script) or die "Cannot execute $script: $!";
                local $/;
                my $output = <$fh>;
                close($fh);

                print $output;
            } else {
                print "HTTP/1.0 404 Not Found\r\n";
                print "Content-Type: text/html\r\n\r\n";
                print "<h1>404 Not Found</h1><p>Script not found: $path</p>";
            }
        } else {
            print "HTTP/1.0 404 Not Found\r\n";
            print "Content-Type: text/html\r\n\r\n";
            print "<h1>404 Not Found</h1>";
        }
    }
}

my $port = 8080;
my $server = MyWebServer->new($port);

print "\n";
print "=" x 60 . "\n";
print "  BMW CarData Plugin - Local Development Server\n";
print "=" x 60 . "\n";
print "\n";
print "Server starting on http://localhost:$port/\n";
print "\n";
print "Open your browser and navigate to:\n";
print "  http://localhost:$port/\n";
print "\n";
print "Press Ctrl+C to stop the server.\n";
print "\n";

$server->run();
