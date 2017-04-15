#!/usr/bin/perl

use strict;
use warnings;
use Parallel::PreForkManager;
use English;

my $Worker = Parallel::PreForkManager->new({
    'ChildHandler'   => \&WorkHandler,
    'ParentCallback' => \&CallbackHandler,
    'ProgressCallback' => {
        'Log' => \&LogCallback,
    },
    'ChildCount'     => 10,
    'JobsPerChild'    => 10,
});

for ( my $i=0;$i<10;$i++ ) {
    $Worker->AddJob({ 'Value' => $i });
}

$Worker->RunJobs();

sub LogCallback {
    my ( $Self, $Data ) = @_;
    #    print "$PID LogCallback: $Data\n";
    return;
}

sub WorkHandler {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'Log', "WORKER $PID - $Val" );

        my $Worker2 = Parallel::PreForkManager->new({
            'ChildHandler'   => \&WorkHandler2,
            'ParentCallback' => \&CallbackHandler,
            'ProgressCallback' => {
                'Log' => \&LogCallback,
            },
            'ChildCount'     => 10,
            'JobsPerChild'    => 10,
        });

        my $Start = $Val * 10;

        for ( my $i=$Start;$i<($Start+10);$i++ ) {
            $Worker2->AddJob({ 'Value' => $i });
        }

        $Worker2->RunJobs();

        return "2Printed $Val in $PID";
}

sub WorkHandler2 {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'Log', "WORKER $PID - $Val" );
        return "Printed $Val in $PID";
}

sub CallbackHandler {
        my ( $Self, $Foo ) = @_;
        print "$Foo\n";
#LogCallback( undef, $Foo );
        return;
};

