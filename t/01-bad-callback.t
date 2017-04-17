#!/usr/bin/perl -T

use strict;
use warnings;
use Parallel::PreForkManager;
use English;

use Test::More;
use Test::Exception;

use List::Util;

plan tests => 2;

{

    my $Worker = Parallel::PreForkManager->new({
        'ChildHandler'   => \&WorkHandler,
        'ProgressCallback' => {
            'Log' => \&LogCallback,
        },
        'ChildCount'     => 2,
        'JobsPerChild'    => 2,
    });

    for ( my $i=0;$i<20;$i++ ) {
        $Worker->AddJob({ 'Value' => $i });
    }

    dies_ok { $Worker->RunJobs(); } 'Unknown callback name';

}

{

    my $Worker = Parallel::PreForkManager->new({
        'ChildHandler'   => \&WorkHandler2,
        'ProgressCallback' => {
            'Log' => \&LogCallback,
        },
        'ChildCount'     => 2,
        'JobsPerChild'    => 2,
    });

    for ( my $i=0;$i<20;$i++ ) {
        $Worker->AddJob({ 'Value' => $i });
    }

    dies_ok { $Worker->RunJobs(); } 'Missing callback sub';

}

sub WorkHandler {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'BadLog', "WorkHandler:ProgressCallback:$Val" );
        return "WorkHandler:Return:$Val";
}

sub WorkHandler2 {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'Log', "WorkHandler:ProgressCallback:$Val" );
        return "WorkHandler:Return:$Val";
}


