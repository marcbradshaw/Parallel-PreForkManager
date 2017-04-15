#!/usr/bin/perl -T

use strict;
use warnings;
use Parallel::PreForkManager;
use English;

use Test::More;

use List::Util qw{ uniq };

plan tests => 1;

my @Results;

my $Worker = Parallel::PreForkManager->new({
    'ChildHandler'   => \&WorkHandler,
    'ParentCallback' => \&CallbackHandler,
    'ProgressCallback' => {
        'Log' => \&LogCallback,
    },
    'ChildCount'     => 10,
});

for ( my $i=0;$i<200;$i++ ) {
    $Worker->AddJob({ 'Value' => $i });
}

$Worker->RunJobs();

@Results = uniq sort @Results;

is( scalar @Results, 20, 'Process count correct' );

sub LogCallback {
    my ( $Self, $Data ) = @_;
    push @Results, "LogCallback:$Data:$PID";
    return;
}

sub WorkHandler {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'Log', "WorkHandler:ProgressCallback:$PID" );
        return "WorkHandler:Return:$PID";
}

sub CallbackHandler {
        my ( $Self, $Val ) = @_;
        push @Results, "CallbackHandler:$Val:PID";
        return;
};

