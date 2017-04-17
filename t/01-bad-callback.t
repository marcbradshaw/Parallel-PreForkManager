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
        'ChildHandler'   => sub {
            my ( $Self ) = @_;
            $Self->ProgressCallback( 'BadLog', "This callback does not exist" );
        },
        'ProgressCallback' => {
            'Log' => \&LogCallback,
        },
        'ChildCount'   => 1,
        'JobsPerChild' => 1,
    });
    $Worker->AddJob({ 'Value' => 1 });
    dies_ok { $Worker->RunJobs(); } 'Unknown callback name';

}

{

    my $Worker = Parallel::PreForkManager->new({
        'ChildHandler'   => sub {
            my ( $Self ) = @_;
            $Self->ProgressCallback( 'Log', "This callback cannot be called" );
        },
        'ProgressCallback' => {
            'Log' => 'This callback cannot be called',
        },
        'ChildCount'   => 1,
        'JobsPerChild' => 1,
    });
    $Worker->AddJob({ 'Value' => 1 });

    dies_ok { $Worker->RunJobs(); } 'Missing callback sub';

}

