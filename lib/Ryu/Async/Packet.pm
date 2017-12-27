package Ryu::Async::Packet;

use strict;
use warnings;

# VERSION

sub new { bless { @_[1..$#_] }, $_[0] }

sub payload { $_[0]->{payload} }
sub from { $_[0]->{from} }

1;

