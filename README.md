# NAME

Parallel::PreForkManager - A manager for pre-forked child worker processes

# DESCRIPTION

Once upon a time, there were X modules on CPAN for managing worker processes, none of the
ones I looked at worked in quite the way I wanted, so now there are X+1.

Easy management of child worker processes.

This module manages a pool of child worker processes, these work through a list of jobs returning
the results to the parent process.

Each child can be made to exit and respawn after a set number of jobs, and can call back
to methods in the parent process if required.

Methods can be defined for child setup and teardown.

[![Code on GitHub](https://img.shields.io/badge/github-repo-blue.svg)](https://github.com/marcbradshaw/Parallel-PreForkManager)

[![Build Status](https://travis-ci.org/marcbradshaw/Parallel-PreForkManager.svg?branch=master)](https://travis-ci.org/marcbradshaw/Parallel-PreForkManager)

[![Open Issues](https://img.shields.io/github/issues/marcbradshaw/Parallel-PreForkManager.svg)](https://github.com/marcbradshaw/Parallel-PreForkManager/issues)

[![Dist on CPAN](https://img.shields.io/cpan/v/Parallel-PreForkManager.svg)](https://metacpan.org/release/Parallel-PreForkManager)

[![CPANTS](https://img.shields.io/badge/cpants-kwalitee-blue.svg)](http://cpants.cpanauthors.org/dist/Parallel-PreForkManager)

# SYNOPSIS

    use Parallel::PreForkManager;
    use English qw( -no_match_vars );

    my $Worker = Parallel::PreForkManager->new({
        'ChildHandler'      => \&WorkHandler,
        'ParentCallback'    => \&CallbackHandler,
        'ProgressCallback'  => {
            'Log' => \&LogCallback,
        },
        'ChildSetupHook'    => \&ChildSetupHook,
        'ChildTeardownHook' => \&ChildTeardownHook,
        'ChildCount'        => 10,
        'JobsPerChild'      => 10,
    });

    for ( my $i=0;$i<300;$i++ ) {
        $Worker->AddJob({ 'Value' => $i });
    }

    $Worker->RunJobs();

    sub ChildSetupHook {
        my ( $Self ) = @_;
        return;
    }

    sub ChildTeardownHook {
        my ( $Self ) = @_;
        return;
    }

    sub LogCallback {
        my ( $Self, $Data ) = @_;
        print "$PID LogCallback: $Data\n";
        return;
    }

    sub WorkHandler {
        my ( $Self, $Thing ) = @_;
        my $Val = $Thing->{'Value'};
        $Self->ProgressCallback( 'Log', "WORKER $PID - $Val" );
        return { 'Data' => "Printed $Val in $PID" };
    }

    sub CallbackHandler {
        my ( $Self, $Result ) = @_;
        my $Foo = $Result->{ 'Data' };
        print "Child returned $Foo to Parent\n";
        return;
    };

# CONSTRUCTOR

- new( $Args )

        my $Worker = Parellel::PreForkManager->new({
            'ChildHandler'     => \&WorkHandler,
            'ParentCallback'   => \&CallbackHandler,
            'ProgressCallback' => {
                'Log' => \&LogCallback,
            },
            'ChildCount'       => 10,
            'JobsPerChild'     => 10,
        });

    - ChildHandler

        The method which will do the work in the child.

    - ParentCallback

        An optional method called in the parent process with the results from each child process.

    - ProgressCallback

        An optional hashref of named methods which child processes may call back to the parent process and run.

    - ChildCount

        Number of child processes to spawn/maintain, default 10.

    - JobsPerChild

        The number of jobs a child process may run before it is respawned.

    - Timeout

        Time limit in seconds for a child process run.

    - WaitComplete

        Wait for all children to complete before returning?  Defaults to 1.

        Call the WaitComplete() method to wait for children manually.

    - ChildSetupHook

        Method which runs in the child when it is spawned.

    - ChildTeardownHook

        Method which runs in the child when it is reaped.

# PUBLIC METHODS

- AddJob( $Job )

    Adds a job to the job queue.  A job is a reference (usually a hashref) which is passed to
    the child worker process for processing.

- RunJobs

    Start the children and run the jobs.

- GetResult

    Called in the parent callback, get a full results dataset from the child.

- WaitComplete

    Run in the parent process, waits for all children to complete.

- ProgressCallback

# USER DEFINED METHODS

- ChildHandler( $Job )

    Passed to the constructor in the ChildHandler element.  This method runs in each
    child to process the job queue.  Its return value is optionally passed back to
    the parent via the defined ParentCallback method.

- ParentCallback( $Data )

    Passed to the constructor in the ParentCallback element.  This method runs in
    the parent after each job completion in the child.  The $Data is passed back
    from the completed child to the parent.

- ProgressCallback( $Data )

    Passed to the constructor in a named element in the ProgressCallback hashred element.
    These methods run in the parent, and are called from a running child by using the 
    ProgressCallback method and given method name from within the child.  The child may
    pass data back to the parent, and the results of the parent call are passed back
    to the running child.

    The parent is blocked from doing any scheduling work while this callback is running.

    This should only be used for short running tasks which need to run in the parent process.

# INTERNAL METHODS

- StartChildren

    Start the right number of child processes.

- StartChild

    Start a single child process.

- Child

    Child process main processing loop.

- Receive

    IPC Receive.

- Send

    IPC Send.

# JSON

Note: All communication between the parent and a child are serialised using JSON.pm, please
be aware of the data type restrictions of JSON serialisation.

# DEPENDENCIES

    Carp
    IO::Handle
    IO::Select
    JSON
    English

# BUGS

Please report bugs via the github tracker.

https://github.com/marcbradshaw/Parallel-PreForkManager/issues

# REFERENCE

Obligatory XKCD reference.

https://xkcd.com/927/

# AUTHORS

Marc Bradshaw, <marc@marcbradshaw.net>

# COPYRIGHT

Copyright (c) 2018, Marc Bradshaw.

# CREDITS

Originally based on code from Parallel::Fork::BossWorker by Jeff Rodriguez, <jeff@jeffrodriguez.com> (c) 2007 and Tim Wilde, <twilde@cpan.org> (c) 2011

# LICENCE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.
