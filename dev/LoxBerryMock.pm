package LoxBerryMock;

# Mock module for LoxBerry modules to enable local development
# This module simulates LoxBerry::System, LoxBerry::Web, LoxBerry::JSON, and LoxBerry::Log
# for testing the web interface locally on Windows

use strict;
use warnings;
use File::Basename;
use Cwd qw(abs_path);

# Find project root directory
our $project_root;
BEGIN {
    $project_root = abs_path(dirname(__FILE__) . "/..");
}

# Export LoxBerry variables (simulate LoxBerry paths)
our $lbptemplatedir = "$project_root/templates";
our $lbpdatadir = "$project_root/data";
our $lbpbindir = "$project_root/bin";
our $lbplogdir = "$project_root/data/logs";
our $lbpconfigdir = "$project_root/config";
our $lbpplugindir = "loxberry-bmw-cardata";

# Create required directories
for my $dir ($lbpdatadir, $lbplogdir, $lbpconfigdir) {
    mkdir($dir) unless -d $dir;
}

# Mock LoxBerry::System
package LoxBerry::System;

sub plugindata {
    return {
        PLUGINDB_TITLE => 'BMW CarData',
        PLUGINDB_VERSION => 'DEV',
        PLUGINDB_FOLDER => 'loxberry-bmw-cardata',
    };
}

# Mock LoxBerry::Web
package LoxBerry::Web;

use HTML::Template;

sub readlanguage {
    my ($template, $filename) = @_;

    # Determine language (default to English)
    my $lang = $ENV{LOXBERRY_LANG} || 'en';
    my $langfile = "$LoxBerryMock::lbptemplatedir/lang/language_$lang.ini";

    # Fallback to English if language file doesn't exist
    unless (-f $langfile) {
        $langfile = "$LoxBerryMock::lbptemplatedir/lang/language_en.ini";
    }

    my %translations;

    if (open(my $fh, '<:encoding(UTF-8)', $langfile)) {
        my $section = '';
        while (my $line = <$fh>) {
            chomp($line);
            $line =~ s/^\s+|\s+$//g; # Trim whitespace

            # Skip empty lines and comments
            next if $line eq '' || $line =~ /^[#;]/;

            # Section header
            if ($line =~ /^\[(.+)\]$/) {
                $section = $1;
                next;
            }

            # Key=Value
            if ($line =~ /^([^=]+)=(.*)$/) {
                my ($key, $value) = ($1, $2);
                $key =~ s/^\s+|\s+$//g;
                $value =~ s/^\s+|\s+$//g;

                my $full_key = $section ? "$section.$key" : $key;
                $translations{$full_key} = $value;
            }
        }
        close($fh);
    }

    return %translations;
}

sub lbheader {
    my ($title, $helplink, $helptemplate) = @_;

    print "Content-Type: text/html; charset=UTF-8\n\n";
    print qq{<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$title - Local Development</title>
    <link rel="stylesheet" href="https://code.jquery.com/ui/1.12.1/themes/base/jquery-ui.css">
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
    <script src="https://code.jquery.com/ui/1.12.1/jquery-ui.min.js"></script>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .loxberry-header {
            background: linear-gradient(to right, #2d5c88, #3d7db3);
            color: white;
            padding: 15px 20px;
            margin: -20px -20px 20px -20px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .loxberry-header h1 {
            margin: 0;
            font-size: 24px;
        }
        .dev-notice {
            background-color: #fff3cd;
            border: 1px solid #ffc107;
            color: #856404;
            padding: 10px 15px;
            margin-bottom: 20px;
            border-radius: 4px;
        }
        .navbar {
            background-color: white;
            border: 1px solid #ddd;
            border-radius: 4px;
            margin-bottom: 20px;
            overflow: hidden;
        }
        .navbar a {
            display: inline-block;
            padding: 12px 20px;
            text-decoration: none;
            color: #333;
            border-right: 1px solid #ddd;
            transition: background-color 0.2s;
        }
        .navbar a:hover {
            background-color: #f0f0f0;
        }
        .navbar a.active {
            background-color: #5cb85c;
            color: white;
        }
        .ui-widget {
            font-family: Arial, sans-serif;
        }
    </style>
</head>
<body>
    <div class="loxberry-header">
        <h1>$title</h1>
    </div>
    <div class="dev-notice">
        <strong>⚠ Local Development Mode</strong> - Running on Windows. Some features may not work as expected.
    </div>
};
}

sub lbfooter {
    print qq{
    <div style="margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 0.9em;">
        Local Development Server - BMW CarData Plugin
    </div>
</body>
</html>
};
}

sub logfile_button_html {
    my %params = @_;
    my $name = $params{NAME} || 'log';
    return qq{<a href="#" class="ui-button ui-widget ui-corner-all" onclick="alert('Log viewing not available in local dev mode'); return false;">View $name Log</a>};
}

sub loglist_html {
    return qq{
        <div class="ui-widget">
            <div class="ui-widget-content ui-corner-all" style="padding: 15px;">
                <p><strong>Log List</strong></p>
                <p>Log viewing is not available in local development mode.</p>
                <p>Check the <code>data/logs/</code> directory for log files.</p>
            </div>
        </div>
    };
}

# Mock LoxBerry::JSON
package LoxBerry::JSON;

# No special functions needed for this plugin

# Mock LoxBerry::Log
package LoxBerry::Log;

sub new {
    my ($class, %params) = @_;
    return bless {}, $class;
}

sub LOGSTART { }
sub LOGINF { }
sub LOGWARN { }
sub LOGERR { }
sub LOGEND { }

# Mock LoxBerry::IO
package LoxBerry::IO;

sub mqtt_connectiondetails {
    return {
        brokeraddress => 'localhost',
        brokerport => 1883,
        brokeruser => 'loxberry',
        brokerpass => 'loxberry',
        udpinport => 11883,
    };
}

1;
