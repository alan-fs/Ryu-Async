package Ryu::Async;
# ABSTRACT: IO::Async support for Ryu stream management
use strict;
use warnings;

our $VERSION = '0.006';

=head1 NAME

Ryu::Async - use L<Ryu> with L<IO::Async>

=head1 SYNOPSIS

# EXAMPLE: examples/synopsis.pl

=head1 DESCRIPTION

This is an L<IO::Async::Notifier> subclass for interacting with L<Ryu>.

=cut

use parent qw(IO::Async::Notifier);

use IO::Async::Handle;
use IO::Async::Listener;
use IO::Async::Process;
use IO::Async::Resolver;
use IO::Async::Signal;
use IO::Async::Socket;
use IO::Async::Stream;
use IO::Async::Timer::Absolute;
use IO::Async::Timer::Countdown;
use IO::Async::Timer::Periodic;

use Ryu::Async::Client;
use Ryu::Async::Packet;
use Ryu::Async::Server;

use Ryu::Sink;
use Ryu::Source;

use URI::udp;
use URI::tcp;

use curry::weak;
use Variable::Disposition qw(retain_future);

use Log::Any qw($log);
use Syntax::Keyword::Try;

=head1 METHODS

=cut

=head2 from

Creates a new L<Ryu::Source> from a thing.

The exact details of this are likely to change in future, but a few things that are expected to work:

 $ryu->from($io_async_stream_instance)
     ->by_line
     ->each(sub { print "Line: $_\n" });
 $ryu->from([1..1000])
     ->sum
     ->each(sub { print "Total was $_\n" });

=cut

sub from {
    use Scalar::Util qw(blessed weaken);
    use namespace::clean qw(blessed weaken);
    my $self = shift;

    if(my $class = blessed $_[0]) {
        if($class->isa('IO::Async::Stream')) {
            return $self->from_stream($_[0]);
        } else {
            die "Unable to determine appropriate source for $class";
        }
    }

    my $src = $self->source(label => 'from');
    if(my $ref = ref $_[0]) {
        if($ref eq 'ARRAY') {
            my @pending = @{$_[0]};
            my $code;
            $code = sub {
                if(@pending) {
                    $src->emit(shift @pending);
                    $self->loop->later($code);
                } else {
                    $src->finish;
                    weaken($_) for $src, $code, $self;
                }
            };
            $code->();
            return $src;
        } else {
            die "Unknown type $ref"
        }
    }

    my %args = @_;
    if(my $dir = $args{directory}) {
        opendir my $handle, $dir or die $!;
        my $code;
        $code = sub {
            if(defined(my $item = readdir $handle)) {
                $src->emit($item) unless $item eq '.' or $item eq '..';
                $self->loop->later($code);
            } else {
                weaken($code);
                closedir $handle or die $!;
                $src->finish
            }
        };
        $code->();
        return $self;
    }
    die "unknown stuff";
}

=head2 from_stream

Create a new L<Ryu::Source> from an L<IO::Async::Stream> instance.

Note that a stream which is not already attached to an L<IO::Async::Notifier>
will be added as a child of this instance.

=cut

sub from_stream {
    use Scalar::Util qw(blessed weaken);
    use namespace::clean qw(blessed weaken);
    my ($self, $stream) = @_;

    my $src = $self->source(label => 'from');
    $stream->configure(
        on_read => sub {
            my ($stream, $buffref, $eof) = @_;
            $log->tracef("Have %d bytes of data, EOF = %s", length($$buffref), $eof ? 'yes' : 'no');
            my $data = substr $$buffref, 0, length $$buffref, '';
            $src->emit($data);
            $src->finish if $eof && !$src->completed->is_ready;
        }
    );
    unless($stream->parent) {
        $self->add_child($stream);
        $src->completed->on_ready(sub {
            $self->remove_child($stream) if $stream->parent;
        });
    }
    return $src;
}

=head2 from_stream

Create a new L<Ryu::Source> that wraps STDIN.

As with other L<IO::Async::Stream> wrappers, this will emit data as soon as it's available,
as raw bytes.

Use L<Ryu::Source/by_line> and L<Ryu::Source/decode> to split into lines and/or decode from UTF-8.

=cut

sub stdin {
    my ($self) = @_;
    return $self->from_stream(
        IO::Async::Stream->new_for_stdin
    )
}

=head2 stdout

Returns a new L<Ryu::Sink> that wraps STDOUT.

=cut

sub stdout {
    my ($self) = @_;
}

=head2 timer

Provides a L<Ryu::Source> which emits an empty string at selected intervals.

Takes the following named parameters:

=over 4

=item * interval - how often to trigger the timer, in seconds (fractional values allowed)

=item * reschedule - type of rescheduling to use, can be C<soft>, C<hard> or C<drift> as documented
in L<IO::Async::Timer::Periodic>

=back

Example:

 $ryu->timer(interval => 1, reschedule => 'hard')
     ->combine_latest(...)

=cut

sub timer {
    my ($self, %args) = @_;
    my $src = $self->source(label => 'timer');
    $self->add_child(
        my $timer = IO::Async::Timer::Periodic->new(
            reschedule => 'hard',
            %args,
            on_tick => $src->curry::weak::emit(''),
        )
    );
    Scalar::Util::weaken($timer);
    $src->on_ready($self->$curry::weak(sub {
        my ($self) = @_;
        return unless $timer;
        $timer->stop if $timer->is_running;
        $self->remove_child($timer)
    }));
    $timer->start;
    $src
}

=head2 source

Returns a new L<Ryu::Source> instance.

=cut

sub source {
    my ($self, %args) = @_;
    my $label = delete($args{label}) // do {
        my $label = (caller 1)[3];
        for($label) {
            s/^Net::Async::/Na/g;
            s/^IO::Async::/Ia/g;
            s/^Web::Async::/Wa/g;
            s/^Tickit::Async::/Ta/g;
            s/^Tickit::Widget::/TW/g;
            s/::([^:]*)$/->$1/;
        }
        $label
    };
    Ryu::Source->new(
        new_future    => $self->loop->curry::weak::new_future,
        apply_timeout => $self->curry::timeout,
        label         => $label,
        %args,
    )
}

=head2 udp_client

Creates a new UDP client.

This will return a L<Ryu::Async::Connection> instance, which provides
a sink for outgoing packets, and a source for incoming responses.

=cut

sub udp_client {
    my ($self, %args) = @_;

    my $uri = delete $args{uri};
    $uri //= 'udp://' . join ':', $args{host} // '*', $args{port} // ();
    $uri = URI->new($uri) unless ref $uri;
    $log->debugf("UDP client for %s", $uri->as_string);

    my $sink = $self->sink(
        label => $args{label} // $uri->as_string,
    );
    $self->add_child(
        my $client = IO::Async::Socket->new(
            on_recv => sub {
                my ($sock, $msg, $addr) = @_;
                warn "Client received $msg from $addr";
            },
        )
    );
    my $f = $client->connect(
        host     => $uri->host || '0.0.0.0',
        service  => $uri->port // 0,
        socktype => 'dgram',
    );
    $f->on_done(sub {
        $log->debugf("UDP client connected");
    })->on_fail(sub {
        $log->errorf("UDP client failed to connect - %s", join ',', @_);
    });
    $sink->source->each(sub {
        my $payload = $_;
        retain_future(
            $f->on_done(sub {
                try {
                    $log->tracef("Sending [%s] to %s", $payload, $uri);
                    $client->send($payload);
                } catch {
                    $log->errorf("Exception when sending: %s", $@);
                }
            })
        );
    });
    Ryu::Async::Client->new(
        outgoing => $sink,
        incoming => undef
    );
}

=head2 udp_server

=cut

sub udp_server {
    my ($self, %args) = @_;

    my $uri = delete $args{uri};
    $uri //= do {
        $args{host} //= '0.0.0.0';
        'udp://' . join ':', $args{host}, $args{port} // ();
    };
    $uri = URI->new($uri) unless ref $uri;
    $log->debugf("UDP server %s", $uri->as_string);

    my $src = $self->source;
    my $sink = $self->sink;

    $self->add_child(
        my $server = IO::Async::Socket->new(
            on_recv => sub {
                my ($sock, $msg, $addr) = @_;
                $log->debugf("UDP server [%s] had %s from %s", $uri->as_string, $msg, $addr);
                $src->emit(
                    Ryu::Async::Packet->new(
                        payload => $msg, 
                        from => $addr
                    )
                )
            },
            on_recv_error => sub {
                my ($sock, $err) = @_;
                $src->fail($err);
            }
        )
    );
    $sink->source->each(sub { $server->send($_->payload, 0, $_->addr) });
    my $port_f = $server->bind(
            service  => $uri->port // 0,
            socktype => 'dgram'
    )->then(sub {
        Future->done($server->write_handle->sockport)
    });
    Ryu::Async::Server->new(
        port     => $port_f,
        incoming => $src,
        outgoing => undef,
    );
}

sub timeout {
    my ($self, $input, $output, $delay) = @_;
    $self->add_child(
        my $timer = IO::Async::Timer::Countdown->new(
            interval => $delay,
            on_expire => sub { $output->fail('timeout') },
        )
    );
    $input->each_while_source(sub { $timer->reset }, $output);
    return $self;
}

=head2 sink

Returns a new L<Ryu::Sink>.

=cut

sub sink {
    my ($self, %args) = @_;
    my $label = delete($args{label}) // do {
        my $label = (caller 1)[3];
        $label =~ s/^Net::Async::/Na/g;
        $label =~ s/^IO::Async::/Ia/g;
        $label =~ s/^Web::Async::/Wa/g;
        $label =~ s/^Tickit::Async::/Ta/g;
        $label =~ s/::([^:]*)$/->$1/;
        $label
    };
    Ryu::Sink->new(
        new_future => $self->loop->curry::weak::new_future,
        label      => $label,
        %args,
    )
}

1;

__END__

=head1 SEE ALSO

=over 4

=item * L<Ryu>

=item * L<IO::Async>

=back

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 LICENSE

Copyright Tom Molesworth 2011-2017. Licensed under the same terms as Perl itself.

