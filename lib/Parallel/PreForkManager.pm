package Parallel::PreForkManager;

use strict;
use warnings;

use Carp;
use IO::Handle;
use IO::Select;
use JSON;
use English qw( -no_match_vars );

my $DEBUG = 0;

sub new {
    my ( $Class, $Args ) = @_;

    croak "No ChildHandler set" if ! exists ( $Args->{'ChildHandler'} );

    my $Self = {
        'ChildHandler'     => $Args->{'ChildHandler'},
        'ChildCount'       => $Args->{'ChildCount'}    || 10,
        'Timeout'          => $Args->{'Timeout'}       || 0,
        'WaitComplete'     => $Args->{'WaitComplete'}  || 1,
        'JobQueue'         => [],
        'Select'           => IO::Select->new(),
    };

    foreach my $Arg ( qw { ParentCallback ProgressCallback JobsPerChild } ) {
        $Self->{ $Arg  } = $Args->{ $Arg } if exists ( $Args->{ $Arg } );
    }

    bless $Self, ref($Class) || $Class;

    return $Self;
}

sub AddJob {
    my ( $Self, $Job ) = @_;
    push @{ $Self->{'JobQueue'} }, $Job;
    return;
}

sub RunJobs {
    my ($Self) = @_;

    # If a worker dies, there's a problem
    local $SIG{CHLD} = sub {
        my $pid = wait();
        if ( exists ( $Self->{'ToChild'}->{$pid} ) ) {
            confess("Worker $pid died.");
        }
    };

    # Start the workers
    $Self->StartChildren();

    # Read from the workers, loop until they all shut down
    while ( %{ $Self->{'ToChild'} } ) {
        READYLOOP:
        while ( my @Ready = $Self->{'Select'}->can_read() ) {
            READLOOP:
            foreach my $fh (@Ready) {
                my $Result = $Self->Receive($fh);

                if ( !$Result ) {
                    $Self->{'Select'}->remove($fh);
                    print STDERR "$fh got eof\n";
                    next READLOOP;
                }

                my $ResultMethod = $Result->{ 'Method' };
                warn "Parent working on Method $ResultMethod\n" if $DEBUG;

                 # Handle the initial request for work
                if ( $ResultMethod eq 'Startup' ) {
                    if ( $#{ $Self->{'JobQueue'} } > -1 ) {
                        #my $Child = $Self->{ 'ToChild' }->{ $Result->{ 'pid' } };
                        my $NextJob = shift( @{ $Self->{'JobQueue'} } );
                        $Self->Send( $Self->{'ToChild'}->{ $Result->{'pid'} }, { 'Job' => $NextJob, }, );
        		next READLOOP;
                    }
        	    else {
                        # Nothing to do, shut down
                        $Self->{'Select'}->remove($fh);
                        my $fh = $Self->{'ToChild'}->{ $Result->{'pid'} };
                        delete( $Self->{'ToChild'}->{ $Result->{'pid'} } );
                        $Self->Send( $fh, { 'Shutdown' => 1, }, );
                        close($fh);
                    }
                }

                # Process the result handler
        	if ( $ResultMethod eq 'Completed' ) {
                    # The child has completed it's work, process the results.
                    if ( $Result->{'Data'} && exists( $Self->{'ParentCallback'} ) ) {
                        &{ $Self->{'ParentCallback'} }( $Self, $Result->{'Data'} );
                    }

                    # If the child has reached its processing limit then shut it down
                    if ( exists( $Result->{'JobsPerChildLimitReached'} ) ) {
                        $Self->{'Select'}->remove($fh);
                        my $fh = $Self->{'ToChild'}->{ $Result->{'pid'} };
                        delete( $Self->{'ToChild'}->{ $Result->{'pid'} } );
                        $Self->Send( $fh, { 'Shutdown' => 1, }, );
                        close($fh);
        		# If there are still jobs to be done then start a new child
                        if ( $#{ $Self->{'JobQueue'} } > -1 ) {
                            $Self->StartChild();
                        }
                        next READLOOP;
                    }

                    # If there's still work to be done, send it to the child
                    if ( $#{ $Self->{'JobQueue'} } > -1 ) {
                        #my $Child = $Self->{ 'ToChild' }->{ $Result->{ 'pid' } };
                        my $NextJob = shift( @{ $Self->{'JobQueue'} } );
                        $Self->Send( $Self->{'ToChild'}->{ $Result->{'pid'} }, { 'Job' => $NextJob, }, );
        		next READLOOP;
                    }

        	    # There is no more work to be done, shut down this child
                    $Self->{'Select'}->remove($fh);
                    my $fh = $Self->{'ToChild'}->{ $Result->{pid} };
                    delete( $Self->{'ToChild'}->{ $Result->{pid} } );
                    close($fh);
        	    next READLOOP;
                }

                if ( $ResultMethod eq 'ProgressCallback' ) {
                    my $Method = $Result->{'ProgressCallbackMethod'};
                    my $Data   = $Result->{'ProgressCallbackData'};
                    if ( exists( $Self->{'ProgressCallback'}->{$Method} ) ) {
                        my $MethodResult = &{ $Self->{'ProgressCallback'}->{$Method} }( $Self, $Data );
                        $Self->Send( $Self->{'ToChild'}->{ $Result->{'pid'} }, $MethodResult );

                    }
                    else {
                        confess "Unknown callback method";
                    }

                    next READLOOP;
                }

            }
        }
    }

    if ( $Self->{ 'WaitComplete' } ) {
        $Self->WaitComplete();
    }

    return;
}

sub WaitComplete {
    my ( $Self ) = @_;
    # Wait for our children so the process table won't fill up
    while ( ( my $pid = wait() ) != -1 ) { }
    return;
}

sub StartChildren {
    my ($Self) = @_;

    # Create a pipe for the workers to communicate to the boss

    my $MaxChildren = $Self->{ 'ChildCount' };
    my $ActualJobs  = scalar @{ $Self->{ 'JobQueue' } };

    if ( $ActualJobs < $MaxChildren ) {
        $MaxChildren = $ActualJobs;
    }

    foreach ( 1 .. $MaxChildren ) {
        $Self->StartChild();
    }

    return;
}

sub StartChild {
    my ($Self) = @_;

    # Open a pipe for the worker
    my ( $FromParent, $FromChild, $ToParent, $ToChild );
    pipe( $FromParent, $ToChild );
    pipe( $FromChild,  $ToParent );

    # Fork off a worker
    my $pid = fork();

    if ($pid) {
        # Parent

        # Close unused pipes
        close($ToParent);
        close($FromParent);

        $Self->{'ToChild'}->{$pid}   = $ToChild;
        $Self->{'FromChild'}->{$pid} = $FromChild;
        $Self->{'Select'}->add($FromChild);

    }
    elsif ( $pid == 0 ) {
        # Child

        warn "Child $PID spawned" if $DEBUG;

        # Close unused pipes
        close($FromChild);
        close($ToChild);

        # Setup communication pipes
        $Self->{'ToParent'} = $ToParent;
        open( STDIN, '/dev/null' );

        # Send the initial request
        $Self->Send( $ToParent, { 'Method' => 'Startup' } );

        # Start processing
        $Self->Child($FromParent);

        # When the worker subroutine completes, exit
        exit 0;
    }
    else {
        confess("Failed to fork: $!");
    }

    return;
}

sub Child {
    my ( $Self, $FromParent ) = @_;
    $Self->{'FromParent'} = $FromParent;

    # Read instructions from the server
    while ( my $Instructions = $Self->Receive($FromParent) ) {

        # If the handler's children die, that's not our business
        $SIG{CHLD} = 'IGNORE';

        if ( exists( $Instructions->{'Shutdown'} ) ) {
            warn "Child $PID shutdown" if $DEBUG;
            exit 0;
        }

        # Execute the handler with the given instructions
        my $Result;
        eval {
            # Handle alarms
            local $SIG{ALRM} = sub {
                die "Child timed out.";
            };

            # Set alarm
            alarm( $Self->{'Timeout'} );

            # Execute the handler and get it's result
            if ( exists( $Self->{'ChildHandler'} ) ) {
                $Result = &{ $Self->{'ChildHandler'} }( $Self, $Instructions->{'Job'} );
            }

            # Disable alarm
            alarm(0);
        };

        # Warn on errors
        if ($@) {
            croak("Child $PID error: $@");
        }

        my $ResultToParent = {
            'Method' => 'Completed',
            'Data'   => $Result,
        };

        if ( exists( $Self->{'JobsPerChild'} ) ) {
            $Self->{'JobsPerChild'} = $Self->{'JobsPerChild'} - 1;
            if ( $Self->{'JobsPerChild'} == 0 ) {
                $ResultToParent->{'JobsPerChildLimitReached'} = 1;
            }
        }

        # Send the result to the server
        $Self->Send( $Self->{'ToParent'}, $ResultToParent );
    }

    warn "Child $PID completed" if $DEBUG;
    exit 0;
}

sub ProgressCallback {
    my ( $Self, $Method, $Data ) = @_;
    $Self->Send( $Self->{'ToParent'}, {
        'Method' => 'ProgressCallback',
        'ProgressCallbackMethod' => $Method,
        'ProgressCallbackData' => $Data,
     } );
    my $Result = $Self->Receive( $Self->{'FromParent'} );
    return $Result;
}

sub Receive {
    my ( $Self, $fh ) = @_;

    # Get a value from the file handle
    my $Value;
    my $Char;
    while ( read( $fh, $Char, 1 ) ) {
        if ( $Char eq "\n" ) {
            last;
        }
        $Value .= $Char;
    }

    # Deserialize the data
    my $Data = eval { decode_json($Value) };

    return $Data;
}

sub Send {
    my ( $Self, $fh, $Value ) = @_;

    $Value->{'pid'} = $PID;

    my $Encoded = encode_json($Value);
    print $fh "$Encoded\n";

    # Force the file handle to flush
    $fh->flush();

    return;
}

1;

__END__

=head1 NAME

Parallel::PreForkManager - A manager for pre-forked child worker processes

=head1 DESCRIPTION

Once upon a time, there were X modules on CPAN for managing worker processes, none of the
ones I looked at worked in quite the way I wanted, so now there are X+1.

Easy management of child worker processes.

This module manages a pool of child worker processes, these work through a list of jobs returning
the results to the parent process.

Each child can be made to exit and respawn after a set number of jobs, and can call back
to methods in the parent process if required.

This module borrows heavily from Parallel::Fork::BossWorker with the following differences.

    * JSON is used for serialisation rather than Data::Dumper

    * Child processes may call back to a method in the parent process.

    * Child processes can have a set limit of jobs they can process before they are respawned.

Much of the heavy lifting is cribbed from Parallel::Fork::BossWorker

=head1 SYNOPSIS

    use Parallel::PreForkManager;

    my $Worker = Parallel::PreForkManager->new({
        'ChildHandler'     => \&WorkHandler,
        'ParentCallback'   => \&CallbackHandler,
        'ProgressCallback' => {
            'Log' => \&LogCallback,
        },
        'ChildCount'       => 10,
        'JobsPerChild'     => 10,
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
        print "Child returned $Foo to Parent\n";
        return;
    };

=head1 CONSTRUCTOR

=over

=item new( $Args )

    my $Worker = Parellel::PreForkManager->new({
        'ChildHandler'     => \&WorkHandler,
        'ParentCallback'   => \&CallbackHandler,
        'ProgressCallback' => {
            'Log' => \&LogCallback,
        },
        'ChildCount'       => 10,
        'JobsPerChild'     => 10,
    });

=head2 ChildHandler

The method which will do the work in the child.

=head2 ParentCallback

An optional method called in the parent process with the results from each child process.

=head2 ProgressCallback

An optional hashref of named methods which child processes may call back to the parent process and run.

=head2 ChildCount

Number of child processes to spawn/maintain, default 10.

=head2 JobsPerChild

The number of jobs a child process may run before it is respawned.

=head2 Timeout

Time limit in seconds for a child process run.

=head2 WaitComplete

Wait for all children to complete before returning?  Defaults to 1.

Call the WaitComplete() method to wait for children manually.

=back

=head1 PUBLIC METHODS

=item AddJob( $Job )

Adds a job to the job queue.  A job is a reference (usually a hashref) which is passed to
the child worker process for processing.

=item RunJobs

Start the children and run the jobs.

=item WaitComplete

Run in the parent process, waits for all children to complete.

=item ProgressCallback

=head1 USER DEFINED METHODS

=item ChildHandler( $Job )

Passed to the constructor in the ChildHandler element.  This method runs in each
child to process the job queue.  Its return value is optionally passed back to
the parent via the defined ParentCallback method.

=item ParentCallback( $Data )

Passed to the constructor in the ParentCallback element.  This method runs in
the parent after each job completion in the child.  The $Data is passed back
from the completed child to the parent.

=item ProgressCallback( $Data )

Passed to the constructor in a named element in the ProgressCallback hashred element.
These methods run in the parent, and are called from a running child by using the 
ProgressCallback method and given method name from within the child.  The child may
pass data back to the parent, and the results of the parent call are passed back
to the running child.

The parent is blocked from doing any scheduling work while this callback is running.

This should only be used for short running tasks which need to run in the parent process.

=head1 INTERNAL METHODS

=item StartChildren

=item StartChild

=item Child

=item Receive

=item Send

=head1 DEPENDENCIES

  Carp
  IO::Handle
  IO::Select
  JSON
  English

=head1 AUTHORS

Marc Bradshaw, E<lt>marc@marcbradshaw.netE<gt>

=head1 COPYRIGHT

Copyright (c) 2017, Marc Bradshaw.

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
