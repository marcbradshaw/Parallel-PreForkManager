package Worker;

use strict;
use warnings;

use Carp;
use IO::Handle;
use IO::Select;
use JSON;
use English qw( -no_match_vars );

my $DEBUG = 1;

sub new {
    my ( $Class, $Args ) = @_;

    croak "No ChildHandler set" if ! exists ( $Args->{'ChildHandler'} );

    my $Self = {
        'ChildHandler'     => $Args->{'ChildHandler'},
        'ChildCount'       => $Args->{'ChildCount'}    || 10,
        'Timeout'          => $Args->{'Timeout'}       || 0,
        'Queue'            => [],
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
    push @{ $Self->{'Queue'} }, $Job;
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
                    if ( $#{ $Self->{'Queue'} } > -1 ) {
                        #my $Child = $Self->{ 'ToChild' }->{ $Result->{ 'pid' } };
                        my $NextJob = shift( @{ $Self->{'Queue'} } );
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
                        if ( $#{ $Self->{'Queue'} } > -1 ) {
                            $Self->StartChild();
                        }
                        next READLOOP;
                    }

                    # If there's still work to be done, send it to the child
                    if ( $#{ $Self->{'Queue'} } > -1 ) {
                        #my $Child = $Self->{ 'ToChild' }->{ $Result->{ 'pid' } };
                        my $NextJob = shift( @{ $Self->{'Queue'} } );
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

    # Wait for our children so the process table won't fill up
    while ( ( my $pid = wait() ) != -1 ) { }

}

sub StartChildren {
    my ($Self) = @_;

    # Create a pipe for the workers to communicate to the boss

    my $MaxChildren = $Self->{ 'ChildCount' };
    my $ActualJobs  = scalar @{ $Self->{ 'Queue' } };

    if ( $ActualJobs < $MaxChildren ) {
        $MaxChildren = $ActualJobs;
    }

    foreach ( 1 .. $MaxChildren ) {
        $Self->StartChild();
    }
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
}

1;
__END__

=head1 NAME

Parallel::Fork::ChildWorker

=head1 SYNOPSIS

    use Parallel::Fork::ChildWorker;

    my $Worker = Worker->new({
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



=head1 DESCRIPTION

Easy management of child worker processes.



This module borrows heavily from Parallel::Fork::BossWorker with the following differences.

    * JSON is used for serialisation rather than Data::Dumper

    * Child processes may call back to a method in the parent process.

    * Child processes can have a set limit of jobs they can process before they are respawned.

Much of the heavy lifting is cribbed from Parallel::Fork::BossWorker

=head1 METHODS

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
