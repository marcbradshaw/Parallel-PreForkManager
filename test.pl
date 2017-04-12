#!/usr/bin/perl

use strict;
use warnings;
use Worker;
use English;

my $Worker = Worker->new({
    'ChildHandler'   => \&WorkHandler,
    'ParentCallback' => \&CallbackHandler,
    'ProgressCallback' => {
        'Log' => \&LogCallback,
    },
    'ChildCount'     => 10,
    'JobsPerChild'    => 10,
});

for ( my $i=0;$i<300;$i++ ) {
    $Worker->AddJob({ 'Value' => $i });
}

$Worker->RunJobs();

sub LogCallback {
    my ( $Self, $Data ) = @_;
    print "$PID LogCallback: $Data\n";
    return;
}

sub WorkHandler {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'Log', "WORKER $PID - $Val" );
        return "Printed $Val in $PID";
}

sub CallbackHandler {
        my ( $Self, $Foo ) = @_;
#        print "$Foo\n";
#LogCallback( undef, $Foo );
        return;
};

