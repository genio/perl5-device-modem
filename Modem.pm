# Device::Modem - a Perl class to interface generic modems (AT-compliant)
#
# Copyright (C) 2002-2003 Cosimo Streppone, cosimo@cpan.org
#
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# Additionally, this is ALPHA software, still needs extensive
# testing and support for generic AT commads, so use it at your own risk,
# and without ANY warranty! Have fun.
#
# $Id: Modem.pm,v 1.32 2004-01-23 00:14:30 cosimo Exp $

package Device::Modem;
$VERSION = sprintf '%d.%02d', q$Revision: 1.32 $ =~ /(\d)\.(\d+)/;

BEGIN {

	if( $^O =~ /Win/io ) {

		require Win32::SerialPort;
		import  Win32::SerialPort;

		# Import line status constants from Win32::SerialPort module
		*Device::Modem::MS_CTS_ON  = *Win32::SerialPort::MS_CTS_ON;
		*Device::Modem::MS_DSR_ON  = *Win32::SerialPort::MS_DSR_ON;
		*Device::Modem::MS_RING_ON = *Win32::SerialPort::MS_RING_ON;
		*Device::Modem::MS_RLSD_ON = *Win32::SerialPort::MS_RLSD_ON;

	} else {

		require Device::SerialPort;
		import  Device::SerialPort;

		# Import line status constants from Device::SerialPort module
		*Device::Modem::MS_CTS_ON = *Device::SerialPort::MS_CTS_ON;
		*Device::Modem::MS_DSR_ON = *Device::SerialPort::MS_DSR_ON;
		*Device::Modem::MS_RING_ON = *Device::SerialPort::MS_RING_ON;
		*Device::Modem::MS_RLSD_ON = *Device::SerialPort::MS_RLSD_ON;

	}
}

use strict;

# Constants definition
use constant CTRL_Z => chr(26);

# TODO: Allow to redefine CR to "\r", "\n" or "\r\n"
use constant CR => "\r";

# Connection defaults
$Device::Modem::DEFAULT_PORT = ( $^O =~ /Win/io ) ? 'COM1' : '/dev/modem';
$Device::Modem::BAUDRATE = 19200;
$Device::Modem::DATABITS = 8;
$Device::Modem::STOPBITS = 1;
$Device::Modem::PARITY   = 'none';
$Device::Modem::TIMEOUT  = 500;     # milliseconds;


# Setup text and numerical response codes
@Device::Modem::RESPONSE = ( 'OK', undef, 'RING', 'NO CARRIER', 'ERROR', undef, 'NO DIALTONE', 'BUSY' );
#%Device::Modem::RESPONSE = (
#	'OK'   => 'Command executed without errors',
#	'RING' => 'Detected phone ring',
#	'NO CARRIER'  => 'Link not established or disconnected',
#	'ERROR'       => 'Invalid command or command line too long',
#	'NO DIALTONE' => 'No dial tone, dialing not possible or wrong mode',
#	'BUSY'        => 'Remote terminal busy'
#);

# object constructor (prepare only object)
sub new {
	my($proto,%aOpt) = @_;                  # Get reference to object
	                                        # Options of object
	my $class = ref($proto) || $proto;      # Get reference to class

	$aOpt{'ostype'} = $^O;                  # Store OSTYPE in object
	$aOpt{'ostype'} =~ /Win/io and $aOpt{'ostype'} = 'windoze';

	# Initialize flags array
	$aOpt{'flags'} = {};

	$aOpt{'port'} ||= $Device::Modem::DEFAULT_PORT;

	# Instance log object
	$aOpt{'log'} ||= 'file';

	# Force logging to file if this is windoze and user requested syslog mechanism
	$aOpt{'log'} = 'file' if( $aOpt{'ostype'} eq 'windoze' && $aOpt{'log'} =~ /syslog/i );
	$aOpt{'loglevel'} ||= 'warning';

	if( ! ref $aOpt{'log'} ) {
		my($method, @options) = split ',', delete $aOpt{'log'};
		my $logclass = 'Device/Modem/Log/'.ucfirst(lc $method).'.pm';
		my $package = 'Device::Modem::Log::'.ucfirst lc $method;
		eval { require $logclass; };
		unless($@) {
			$aOpt{'_log'} = $package->new( $class, @options );
		}
	} else {
		# User passed an already instanced log object
		$aOpt{'_log'} = $aOpt{'log'};
	}

	if( ref $aOpt{'_log'} && $aOpt{'_log'}->can('loglevel') ) {
		$aOpt{'_log'}->loglevel($aOpt{'loglevel'});
	}

	bless \%aOpt, $class;                   # Instance $class object
}

sub attention {
	my $self = shift;
	$self->log->write('info', 'sending attention sequence...');

	# Send attention sequence
	$self->atsend('+++');

	# Wait 200 milliseconds
	$self->wait(200);
	$self->answer();
}

#
# Dial telephone number
#
# dial( number, timeout )
# example: dial( '0289011124', 45 ) (timeout in seconds)
#
# if number to dial is 1-digit, takes number from address book
# [ see store_number() ]
#
sub dial {
	my($self, $number, $timeout) = @_;
	my $ok = 0;

	# Default timeout in seconds
	$timeout ||= 30;

	# Check if we have already dialed some number...
	if( $self->flag('CARRIER') ) {
		$self->log->write( 'warning', 'line is already connected, ignoring dial()' );
		return;
	}

	# Check if no number supplied
	if( ! defined $number ) {
		#
		# XXX Here we could enable ATDL command (dial last number)
		#
		$self->log->write( 'warning', 'cannot dial without a number!' );
		return;
	}

	# Remove all non number chars plus some others allowed
	$number =~ s/[^0-9,\(\)\*\-\s]//g;

	# Dial number and wait for response
	if( length $number == 1 ) {
		$self->log->write('info', 'dialing address book number ['.$number.']' );
		$self->atsend( 'ATDS' . $number . CR );
	} else {
		$self->log->write('info', 'dialing number ['.$number.']' );
		$self->atsend( 'ATDT' . $number . CR );
	}

	# XXX Check response times here (timeout!)
	my $ans = $self->answer(undef, $timeout * 1000 );

	$ok = 1 if index( $ans, 'CONNECT' ) > -1;

	# Turn on/off `CARRIER' flag
	$self->flag('CARRIER', $ok);

	$self->log->write('info', 'dialing result = '.$ok);
	return wantarray ? ($ok, $ans) : $ok;
}

# Enable/disable local echo of commands (enabling echo can cause everything else to fail, I think)
sub echo {
	my($self, $lEnable) = @_;

	$self->log->write( 'info', ( $lEnable ? 'enabling' : 'disabling' ) . ' echo' );
	$self->atsend( ($lEnable ? 'ATE1' : 'ATE0') . CR );

	$self->answer('OK');
}

# Terminate current call (XXX not tested)
sub hangup {
	my $self = shift;

	$self->log->write('info', 'hanging up...');
	$self->attention();
	$self->atsend( 'ATH0' . CR );
	$self->_reset_flags();
	$self->answer();
}

# Checks if modem is enabled (for now, it works ok for modem OFF/ON case)
sub is_active {
	my $self = shift;
	my $lOk;

	$self->log->write('info', 'testing modem activity on port '.$self->options->{'port'} );

	# Modem is active if already connected to a line
	if( $self->flag('CARRIER') ) {

		$self->log->write('info', 'carrier is '.$self->flag('CARRIER').', modem is connected, it should be active');
		$lOk = 1;

	} else {

		# XXX Old mode to test modem ... 
		# Try sending an echo enable|disable command
		#$self->attention();
		#$self->verbose(0);
		#$lOk = $self->verbose(1);

		# If DSR signal is on, modem is active
		my %sig = $self->status();
		$lOk = $sig{DSR};
		undef %sig;

		# If we have no success, try to reset
		if( ! $lOk ) {
			$self->log->write('warning', 'modem not responding... trying to reset');
			$lOk = $self->reset();
		}

	}

	$self->log->write('info', 'modem reset result = '.$lOk);

	return $lOk;
}

# Take modem off hook, prepare to dial
sub offhook {
	my $self = shift;

	$self->log->write('info', 'taking off hook');
	$self->atsend( 'ATH1' . CR );

	$self->flag('OFFHOOK', 1);

	return 1;
}

# Get/Set S* registers value:  S_register( number [, new_value] )
# returns undef on failure ( zero is a good value )
sub S_register {
	my $self = shift;
	my $register = shift;
	my $value = 0;

	return unless $register;

	my $ok;

	# If `new_value' supplied, we want to update value of this register
	if( @_ ) {

		my $new_value = shift;
		$new_value =~ s|\D||g;
		$self->log->write('info', 'storing value ['.$new_value.'] into register S'.$register);
		$self->atsend( sprintf( 'AT S%02d=%d' . CR, $register, $new_value ) );


		$value = ( index( $self->answer, 'OK' ) != -1 ) ? $new_value : undef;

	} else {

		$self->atsend( sprintf( 'AT S%d?' . CR, $register ) );
		($ok, $value) = $self->parse_answer();

		if( index($ok, 'OK') != -1 ) {
			$self->log->write('info', 'value of S'.$register.' register seems to be ['.$value.']');
		} else {
			$value = undef;
			$self->log->write('error', 'error reading value of S'.$register.' register');
		}

	}

	# Return updated value of register
	$self->log->write('info', 'S'.$register.' = '.$value);

	return $value;
}

# Repeat the last commands (this comes gratis with `A/' at-command)
sub repeat {
	my $self = shift;

	$self->log->write('info', 'repeating last command' );
	$self->atsend( 'A/' . CR );

	$self->answer();
}

# Complete modem reset
sub reset {
	my $self = shift;

	$self->log->write('warning', 'resetting modem on '.$self->{'port'} );
	$self->hangup();
	$self->send_init_string();
	$self->_reset_flags();
	return $self->answer();
}

# Return an hash with the status of main modem signals
sub status {
	my $self = shift;
	$self->log->write('info', 'getting modem line status on '.$self->{'port'});

	# This also relies on Device::SerialPort
	my $status = $self->port->modemlines();

	# See top of module for these constants, exported by (Win32|Device)::SerialPort
	my %signal = (
		CTS  => $status & Device::Modem::MS_CTS_ON,
		DSR  => $status & Device::Modem::MS_DSR_ON,
		RING => $status & Device::Modem::MS_RING_ON,
		RLSD => $status & Device::Modem::MS_RLSD_ON
	);

	$self->log->write('info', 'modem on '.$self->{'port'}.' status is ['.$status.']');
	$self->log->write('info', "CTS=$signal{CTS} DSR=$signal{DSR} RING=$signal{RING} RLSD=$signal{RLSD}");

	return %signal;
}

# Of little use here, but nice to have it
# restore_factory_settings( profile )
# profile can be 0 or 1
sub restore_factory_settings {
	my $self = shift;
	my $profile = shift;
	$profile = 0 unless defined $profile;

	$self->log->write('warning', 'restoring factory settings '.$profile.' on '.$self->{'port'} );
	$self->atsend( 'AT&F'.$profile . CR);

	$self->answer();
}

# Store telephone number in modem's internal address book, to dial later
# store_number( position, number )
sub store_number {
	my( $self, $position, $number ) = @_;
	my $ok = 0;

	# Check parameters
	unless( defined($position) && $number ) {
		$self->log->write('warning', 'store_number() called with wrong parameters');
		return $ok;
	}

	$self->log->write('info', 'storing number ['.$number.'] into memory ['.$position.']');

	# Remove all non-numerical chars from position and number
	$position =~ s/\D//g;
	$number   =~ s/[^0-9,]//g;

	$self->atsend( sprintf( 'AT &Z%d=%s' . CR, $position, $number ) );

	if( index( $self->answer(), 'OK' ) != -1 ) {
		$self->log->write('info', 'stored number ['.$number.'] into memory ['.$position.']');
		$ok = 1;
	} else {
		$self->log->write('warning', 'error storing number ['.$number.'] into memory ['.$position.']');
		$ok = 0;
	}

	return $ok;
}

# Enable/disable verbose response messages against numerical response messages
# XXX I need to manage also numerical values...
sub verbose {
	my($self, $lEnable) = @_;

	$self->log->write( 'info', ( $lEnable ? 'enabling' : 'disabling' ) . ' verbose messages' );
	$self->atsend( ($lEnable ? 'ATQ0V1' : 'ATQ0V0') . CR );

	$self->answer('OK');
}


sub wait {
	my( $self, $msec ) = @_;

	$self->log->write('debug', 'waiting for '.$msec.' msecs');

	# Perhaps Time::HiRes here is not so useful, since I tested `select()' system call also on Windows
	select( undef, undef, undef, $msec / 1000 );
	return 1;

}

# Set a named flag. Flags are now: OFFHOOK, CARRIER
sub flag {
	my $self = shift;
	my $cFlag = uc shift;

	$self->{'_flags'}->{$cFlag} = shift() if @_;

	$self->{'_flags'}->{$cFlag};
}

# reset internal flags that tell the status of modem (XXX to be extended)
sub _reset_flags {
	my $self = shift();

	map { $self->flag($_, 0) }
		'OFFHOOK', 'CARRIER';
}

# initialize modem with some basic commands (XXX &C0)
# send_init_string( [my_init_string] )
# my_init_string goes without 'AT' prefix
sub send_init_string {
	my($self, $cInit) = @_;
	$self->attention();
	$cInit = $self->options->{'init_string'} unless defined $cInit;
	$self->atsend('AT '.$cInit. CR );
	$self->answer();
}

# returns log object reference or nothing if it is not defined
sub log {
	my $me = shift;
	if( ref $me->{'_log'} ) {
		return $me->{'_log'};
	} else {
		return {};
	}
}

# instances (Device|Win32)::SerialPort object and initializes communications
sub connect {
	my $me = shift();

	my %aOpt = ();
	if( @_ ) {
		%aOpt = @_;
	}

	my $lOk = 0;

	# Set default values if missing
	$aOpt{'baudrate'} ||= $Device::Modem::BAUDRATE;
	$aOpt{'databits'} ||= $Device::Modem::DATABITS;
	$aOpt{'parity'}   ||= $Device::Modem::PARITY;
	$aOpt{'stopbits'} ||= $Device::Modem::STOPBITS;

	# Store communication options in object
	$me->{'_comm_options'} = \%aOpt;

	# Connect on serial (use different mod for win32)
	if( $me->ostype eq 'windoze' ) {
		$me->port( new Win32::SerialPort($me->{'port'}) );
	} else {
		$me->port( new Device::SerialPort($me->{'port'}) );
	}

	# Check connection
	unless( ref $me->port ) {
		$me->log->write( 'error', '*FAILED* connect on '.$me->{'port'} );
		return $lOk;
	}

	# Set communication options
	my $oPort = $me->port;
	$oPort -> baudrate ( $me->options->{'baudrate'} );
	$oPort -> databits ( $me->options->{'databits'} );
	$oPort -> stopbits ( $me->options->{'stopbits'} );
	$oPort -> parity   ( $me->options->{'parity'}   );

	# Non configurable options
	$oPort -> buffers         ( 10000, 10000 );
	$oPort -> handshake       ( 'none' );
	$oPort -> read_const_time ( 100 );           # was 500
	$oPort -> read_char_time  ( 10 );

	$oPort -> are_match       ( 'OK' );
	$oPort -> lookclear;

	$oPort -> write_settings;
	$oPort -> purge_all;

	$me-> log -> write('info', 'sending init string...' );

	# Set default initialization string if none supplied
	$me->options->{'init_string'} ||= 'H0 Z S7=45 S0=0 Q0 V1 E0 &C0 X4';

	$me-> send_init_string( $me->options->{'init_string'} );
	$me-> _reset_flags();

	# Disable local echo
	$me-> echo(0);

	$me-> log -> write('info', 'Ok connected' );
	$me-> {'CONNECTED'} = 1;

}

# $^O is stored into object
sub ostype {
	my $self = shift;
	$self->{'ostype'};
}

# returns Device::SerialPort reference to hash options
sub options {
	my $self = shift();
	@_ ? $self->{'_comm_options'} = shift()
	   : $self->{'_comm_options'};
}

# returns Device::SerialPort object handle
sub port {
	my $self = shift();
	@_ ? $self->{'_comm_object'} = shift()
	   : $self->{'_comm_object'};
}

# disconnect serial port
sub disconnect {
	my $me = shift;
	$me->port->close();
	$me->log->write('info', 'Disconnected from '.$me->{'port'} );
}

# Send AT command to device on serial port (command must include CR for now)
sub atsend {
	my( $me, $msg ) = @_;
	my $cnt = 0;

	# Write message on port
	$me->port->purge_all();
	$cnt = $me->port->write($msg);
	$me->wait(400);

	$me->port->write_drain() unless $me->ostype eq 'windoze';
	$me->log->write('debug', 'atsend: wrote '.$cnt.'/'.length($msg).' chars');

	# If wrote all chars of `msg', we are successful
	return $cnt == length $msg;
}

# answer() takes strings from the device until a pattern
# is encountered or a timeout happens.
sub _answer {
	my $me = shift;
	my($expect, $timeout) = @_;
	my $time_slice = 50;                       # single cycle wait time

	# If we expect something, we must first match against serial input
	my $done = (defined $expect and $expect ne '');

	#$me->log->write('debug', 'answer: expecting ['.($expect||'').']'.($timeout ? ' or '.($timeout/1000).' seconds timeout' : '' ) );

	# Main read cycle
	my $cycles = 0;
	my $idle_cycles = 0;
	my $answer;
	my $start_time = time();
	my $end_time   = 0;

	# If timeout was defined, check max time (timeout is in milliseconds)
	#$me->log->write('debug', 'answer: timeout value is '.$timeout);

	if( defined $timeout && $timeout > 0 ) {
		$end_time = $start_time + ($timeout / 1000);
		#$me->log->write( debug => 'answer: end time set to '.$end_time );
	}

	do {

		my($howmany, $what) = $me->port->read(10);

		# Timeout count incremented only on empty readings
		if( defined $what && $howmany > 0 ) {

			# Add received chars to answer string
			$answer .= $what;

			# Check if buffer matches "expect string"
			if( defined $expect ) {
				$done = ( defined $answer && $answer =~ $expect ) ? 1 : 0;
			}

			#$me->log->write('debug', 'time_slice='.$time_slice);
			$me->wait($time_slice) unless $done;

		} else {

			$done = 1;

		}

		# Check if we reached max time for timeout (only if end_time is defined)
		if( $howmany == 0 && $end_time > 0 ) {
			$done = ( time() >= $end_time ) ? 1 : 0;
		}

		#$me->log->write('debug', 'done = '.$done );
		#$me->log->write('debug', 'end_time='.$end_time.' now='.time().' start_time='.$start_time );

	} while (not $done);

	$me->log->write('debug', 'answer: read ['.($answer||'').']' );

	# Flush receive and trasmit buffers
	$me->port->purge_all;

	return $answer;

} 

sub answer {

	my $me = shift();
	my $answer = $me->_answer(@_);

	# Trim result of beginning and ending CR+LF (XXX)
	if( defined $answer ) {
		$answer =~ s/^[\r\n]+//;
		$answer =~ s/[\r\n]+$//;
	}

	$me->log->write('info', 'answer: `'.($answer||'').'\'' );

	return $answer;
}


# parse_answer() cleans out answer() result as response code +
# useful information (useful in informative commands, for example
# Gsm command AT+CGMI)
sub parse_answer {
	my $me = shift;

	my $buff = $me->answer( @_ );

	# Separate response code from information
	my @buff = split /[\r\n]+/o, $buff;

	# Remove all empty lines before/after response
	shift @buff while $buff[0]  =~ /^[\r\n]+/o;
	pop   @buff while $buff[-1] =~ /^[\r\n]+/o;

	# Extract responde code
	my $code = pop @buff;
	$buff = join( CR, @buff );

	return
		wantarray
		? ($code, @buff)
		: $buff;

}



1;


=head1 NAME

Device::Modem - Perl extension to talk to modem devices connected via serial port

=head1 WARNING

This is B<BETA> software, so use it at your own risk,
and without B<ANY> warranty! Have fun.

=head1 SYNOPSIS

  use Device::Modem;

  my $modem = new Device::Modem( port => '/dev/ttyS1' );

  if( $modem->connect( baudrate => 9600 ) ) {
      print "connected!\n";
  } else {
      print "sorry, no connection with serial port!\n";
  }

  $modem->attention();          # send `attention' sequence (+++)

  ($ok, $answer) = $modem->dial('02270469012');  # dial phone number
  $ok = $modem->dial(3);        # 1-digit parameter = dial number stored in memory 3

  $modem->echo(1);              # enable local echo (0 to disable)

  $modem->offhook();            # Take off hook (ready to dial)
  $modem->hangup();             # returns modem answer

  $modem->is_active();          # Tests whether modem device is active or not
                                # So far it works for modem OFF/ modem ON condition

  $modem->reset();              # hangup + attention + restore setting 0 (Z0)

  $modem->restore_factory_settings();  # Handle with care!
  $modem->restore_factory_settings(1); # Same with preset profile 1 (can be 0 or 1)

  $modem->send_init_string();   # Send initialization string
                                # Now this is fixed to 'AT H0 Z S7=45 S0=0 Q0 V1 E0 &C0 X4'

  # Get/Set value of S1 register
  my $S1 = $modem->S_register(1);
  my $S1 = $modem->S_register(1, 55); # Don't do that if you definitely don't know!

  # Get status of managed signals (CTS, DSR, RLSD, RING)
  my %signal = $modem->status();
  if( $signal{DSR} ) { print "Data Set Ready signal active!\n"; }

  # Stores this number in modem memory number 3
  $modem->store_number(3, '01005552817');

  $modem->repeat();             # Repeat last command

  $modem->verbose(1);           # Normal text responses (0=numeric codes)

  # Some raw AT commands
  $modem->atsend( 'ATH0' );
  print $modem->answer();

  $modem->atsend( 'ATDT01234567' . Device::Modem::CR );
  print $modem->answer();


=head1 DESCRIPTION

C<Device::Modem> class implements basic B<AT (Hayes) compliant> device abstraction.
It can be inherited by sub classes (as C<Device::Gsm>), which are based on serial connections.


=head2 Things C<Device::Modem> can do

=over 4

=item *

connect to a modem on your serial port

=item *

test if the modem is alive and working

=item *

dial a number and connect to a remote modem

=item *

work with registers and settings of the modem

=item *

issue standard or arbitrary C<AT> commands, getting results from modem

=back

=head2 Things C<Device::Modem> can't do yet

=over 4

=item *

Transfer a file to a remote modem

=item *

Control a terminal-like (or a PPP) connection. This should really not
be very hard to do anyway.

=item *

Many others...

=back

=head2 Things it will never be able to do

=over 4

=item *

Coffee :-)

=back


=head2 Examples

In the `examples' directory, there are some scripts that should work without big problems,
that you can take as (yea) examples:

=over 4

=item `examples/active.pl'

Tests if modem is alive

=item `examples/dial.pl'

Dials a phone number and display result of call

=item `examples/shell.pl'

(Very) poor man's minicom/hyperterminal utility

=back

=head1 METHODS

=head2 answer()

One of the most used methods, waits for an answer from the device. It waits until
$timeout (seconds) is reached (but don't rely on this time to be very correct) or until an
expected string is encountered. Example:

	$answer = $modem->answer( [$expect [, $timeout]] )

Returns C<$answer> that is the string received from modem stripped of all
B<Carriage Return> and B<Line Feed> chars B<only> at the beginning and at the end of the
string. No in-between B<CR+LF> are stripped.

Note that if you need the raw answer from the modem, you can use the _answer() (note
that underscore char before answer) method, which does not strip anything from the response,
so you get the real modem answer string.

Parameters:

=over 4

=item *

C<$expect> - Can be a regexp compiled with C<qr> or a simple substring. Input coming from the
modem is matched against this parameter. If input matches, result is returned.

=item *

C<$timeout> - Expressed in seconds. After that time, answer returns result also if nothing
has been received. Example: C<10>. Default: C<0.2>

=back



=head2 atsend()

Sends a raw C<AT> command to the device connected. Note that this method is most used
internally, but can be also used to send your own custom commands. Example:

	$ok = $modem->atsend( $msg )

The only parameter is C<$msg>, that is the raw AT command to be sent to
modem expressed as string. You must include the C<AT> prefix and final
B<Carriage Return> and/or B<Line Feed> manually. There is the special constant
C<CR> that can be used to include such a char sequence into the at command.

Returns C<$ok> flag that is true if all characters are sent successfully, false
otherwise.

Example:

	# Enable verbose messages
	$modem->atsend( 'AT V1' . Device::Modem::CR );

	# The same as:
	$modem->verbose(1);


=head2 attention()

This command sends an B<attention> sequence to modem. This allows modem
to pass in B<command state> and accept B<AT> commands. Example:

	$ok = $modem->attention()

=head2 connect()

Connects C<Device::Modem> object to the specified serial port.
There are options (the same options that C<Device::SerialPort> has) to control
the parameters associated to serial link. Example:

	$ok = $modem->connect( [%options] )

List of allowed options follows:

=over 4

=item C<baudrate>

Controls the speed of serial communications. The default is B<19200> baud, that should
be supported by all modern modems. However, here you can supply a custom value.
Common speed values: 300, 1200, 2400, 4800, 9600, 19200, 38400, 57600,
115200.
This parameter is handled directly by C<Device::SerialPort> object.

=item C<databits>

This tells how many bits your data word is composed of.
Default (and most common setting) is C<8>.
This parameter is handled directly by C<Device::SerialPort> object.

=item C<init_string>

Custom initialization string can be supplied instead of the built-in one, that is the
following: C<H0 Z S7=45 S0=0 Q0 V1 E0 &C0 X4>, that is taken shamelessly from
C<minicom> utility, I think.

=item C<parity>

Controls how parity bit is generated and checked.
Can be B<even>, B<odd> or B<none>. Default is B<none>.
This parameter is handled directly by C<Device::SerialPort> object.

=item C<stopbits>

Tells how many bits are used to identify the end of a data word.
Default (and most common usage) is C<1>.
This parameter is handled directly by C<Device::SerialPort> object.

=back



=head2 dial()

Takes the modem off hook, dials the specified number and returns modem answer.
Usage:

	# Simple usage (timeout is optional)
	$ok = $modem->dial( $number [,$timeout] )

	# List context: allows to get at exact modem answer
	# like `CONNECT 19200/...', `BUSY', `NO CARRIER', ...
	($ok, $answer) = $modem->dial( $number [,$timeout] )

If called in B<scalar context>, returns only success of connection. If modem answer
contains C<CONNECT> string, C<dial()> returns successful state, else false value
is returned.

If called in B<list context>, returns the same C<$ok> flag, but also the exact
modem answer to the dial operation in the C<$answer> scalar. C<$answer> typically
can contain strings like C<CONNECT 19200> or C<NO CARRIER>, C<BUSY>, ... all standard
modem answers to a dial command.

Parameters are:

=over 4

=item *

C<$number> - this is the phone number to dial. If C<$number> is only 1 digit, it is interpreted
as: B<dial number in my address book position C<$number>>. So if your code is:

	$modem->dial( 2, 10 );

This means: dial number in the modem internal address book (see C<store_number> for a way to
read/write address book) in position number B<2> and wait for a timeout of B<10> seconds.

=item *

C<$timeout> - timeout expressed in seconds to wait for the remote device to answer.
Please do not expect an B<exact> wait for the number of seconds you specified. I'm still
studying how to do that exactly.

=back


=head2 disconnect()

Disconnects C<Device::Modem> object from serial port. This method calls underlying
C<disconnect()> of C<Device::SerialPort> object.
Example:

	$modem->disconnect();

=head2 echo()

Enables or disables local echo of commands. This is managed automatically by C<Device::Modem>
object. Normally you should not need to worry about this. Usage:

	$ok = $modem->echo( $enable )

=head2 hangup()

Does what it is supposed to do. Hang up the phone thus terminating any active call.
Usage:

	$ok = $modem->hangup();

=head2 is_active()

Can be used to check if there is a modem attached to your computer.
If modem is alive and responding (on serial link, not to a remote call),
C<is_active()> returns true (1), otherwise returns false (0).

Test of modem activity is done through DSR (Data Set Ready) signal. If
this signal is in off state, modem is probably turned off, or not working.
From my tests I've found that DSR stays in "on" state after more or less
one second I turn off my modem, so know you know that.

Example:

	if( $modem->is_active() ) {
		# Ok!
	} else {
		# Modem turned off?
	}

=head2 log()

Simple accessor to log object instanced at object creation time.
Used internally. If you want to know the gory details, see C<Device::Modem::Log::*> objects.
You can also see the B<examples> for how to log something without knowing
all the gory details.

Hint:
	$modem->log->write('warning', 'ok, my log message here');

=head2 new()

C<Device::Modem> constructor. This takes several options. A basic example:

	my $modem = Device::Modem->new( port => '/dev/ttyS0' );

if under Linux or some kind of unix machine, or

	my $modem = Device::Modem->new( port => 'COM1' );

if you are using a Win32 machine.

This builds the C<Device::Modem> object with all the default parameters.
This should be fairly usable if you want to connect to a real modem.
Note that I'm testing it with a B<3Com US Robotics 56K Message> modem
at B<19200> baud and works ok.

List of allowed options:

=over 4

=item *

C<port> - serial port to connect to. On Unix, can be also a convenient link as
F</dev/modem> (the default value). For Win32, C<COM1,2,3,4> can be used.

=item *

C<log> - this specifies the method and eventually the filename for logging.
Logging process with C<Device::Modem> is controlled by B<log plugins>, stored under
F<Device/Modem/Log/> folder. At present, there are two main plugins: C<Syslog> and C<File>.
C<Syslog> does not work with Win32 machines.
When using C<File> plug-in, all log information will be written to a default filename
if you don't specify one yourself. The default is F<%WINBOOTDIR%\temp\modem.log> on
Win32 and F</var/log/modem.log> on Unix.

Also there is the possibility to pass a B<custom log object>, if this object
provides the following C<write()> call:

	$log_object->write( $loglevel, $logmessage )

You can simply pass this object (already instanced) as the C<log> property.

Examples:

	# For Win32, default is to log in "%WINBOOTDIR%/temp/modem.log" file
	my $modem = Device::Modem->new( port => 'COM1' );

	# Unix, custom logfile
	my $modem = Device::Modem->new( port => '/dev/ttyS0', log => 'file,/home/neo/matrix.log' )

	# With custom log object
	my $modem = Device::modem->new( port => '/dev/ttyS0', log => My::LogObj->new() );

=item *

C<loglevel> - default logging level. One of (order of decrescent verbosity): C<debug>,
C<verbose>, C<notice>, C<info>, C<warning>, C<err>, C<crit>, C<alert>, C<emerg>.

=back


=head2 offhook()

Takes the modem "off hook", ready to dial. Normally you don't need to use this.
Also C<dial()> goes automatically off hook before dialing.



=head2 parse_answer()

This method works like C<answer()>, it accepts the same parameters, but it
does not return the raw modem answer. Instead, it returns the answer string
stripped of all B<CR>/B<LF> characters at the beginning B<and> at the end.

C<parse_answer()> is meant as an easy way of extracting result code
(C<OK>, C<ERROR>, ...) and information strings that can be sent by modem
in response to specific commands. Example:

	> AT xSHOW_MODELx<CR>
	US Robotics 56K Message
	OK
	>

In this example, C<OK> is the result and C<US Robotics 56K Message> is the
informational message.

In fact, another difference with C<answer()> is in the return value(s).
Here are some examples:

	$modem->atsend( '?my_at_command?' );
	$answer = $modem->parse_answer();

where C<$answer> is the complete response string, or:

	($result, @lines) = $modem->parse_answer();

where C<$result> is the C<OK> or C<ERROR> final message and C<@lines> is
the array of information messages (one or more lines). For the I<model> example,
C<$result> would hold "C<OK>" and C<@lines> would consist of only 1 line with
the string "C<US Robotics 56K Message>".



=head2 port()

Used internally. Accesses the C<Device::SerialPort> underlying object. If you need to
experiment or do low-level serial calls, you may want to access this. Please report
any usage of this kind, because probably (?) it is possible to include it in a higher
level method.


=head2 repeat()

Repeats the last C<AT> command issued.
Usage:

	$ok = $modem->repeat()


=head2 reset()

Tries in any possible way to reset the modem to the starting state, hanging up all
active calls, resending the initialization string and preparing to receive C<AT>
commands.



=head2 restore_factory_settings()

Restores the modem default factory settings. There are normally two main "profiles",
two different memories for all modem settings, so you can load profile 0 and profile 1,
that can be different depending on your modem manufacturer.

Usage:

	$ok = $modem->restore_factory_settings( [$profile] )

If no C<$profile> is supplied, C<0> is assumed as default value.

Check on your modem hardware manual for the meaning of these B<profiles>.



=head2 S_register()

Gets or sets an B<S register> value. These are some internal modem registers that
hold important information that controls all modem behaviour. If you don't know
what you are doing, don't use this method. Usage:

	$value = $modem->S_register( $reg_number [, $new_value] );

C<$reg_number> ranges from 0 to 99 (sure?).
If no C<$new_value> is supplied, return value is the current register value.
If a C<$new_value> is supplied (you want to set the register value), return value
is the new value or C<undef> if there was an error setting the new value.

<!-- Qui &egrave; spiegata da cani -->

Examples:

	# Get value of S7 register
	$modem->S_register(7);

	# Set value of S0 register to 0
	$modem->S_register(0, 0);


=head2 send_init_string()

Sends the initialization string to the connected modem. Usage:

	$ok = $modem->send_init_string( [$init_string] );

If you specified an C<init_string> as an option to C<new()> object constructor,
that is taken by default to initialize the modem.
Else you can specify C<$init_string> parameter to use your own custom intialization
string. Be careful!

=head2 status()

Returns status of main modem signals as managed by C<Device::SerialPort> (or C<Win32::SerialPort>) objects.
The signals reported are:

=over 4

=item CTS

Clear to send

=item DSR

Data set ready

=item RING

Active if modem is ringing

=item RLSD

??? Released line ???

=back

Return value of C<status()> call is a hash, where each key is a signal name and
each value is > 0 if signal is active, 0 otherwise.
Usage:

	...
	my %sig = $modem->status();
	for ('CTS','DSR','RING','RLSD') {
		print "Signal $_ is ", ($sig{$_} > 0 ? 'on' : 'off'), "\n";
	}

=head2 store_number()

Store telephone number in modem internal address book, to be dialed later (see C<dial()> method).
Usage:

	$ok = $modem->store_number( $position, $number )

where C<$position> is the address book memory slot to store phone number (usually from 0 to 9),
and C<$number> is the number to be stored in the slot.
Return value is true if operation was successful, false otherwise.

=head2 verbose()

Enables or disables verbose messages. This is managed automatically by C<Device::Modem>
object. Normally you should not need to worry about this. Usage:

	$ok = $modem->verbose( $enable )

=head2 wait()

Waits (yea) for a given amount of time (in milliseconds). Usage:

	$modem->wait( [$msecs] )

Wait is implemented via C<select> system call.
Don't know if this is really a problem on some platforms.





=head1 REQUIRES

=over 4

=item Device::SerialPort (Win32::SerialPort for Win32 machines)

=back

=head1 EXPORT

None



=head1 TO-DO

=over 4

=item AutoScan

An AT command script with all interesting commands is run
when `autoscan' is invoked, creating a `profile' of the
current device, with list of supported commands, and database
of brand/model-specific commands

=item Serial speed autodetect

Now if you connect to a different baud rate than that of your modem,
probably you will get no response at all. It would be nice if C<Device::Modem>
could auto-detect the speed to correctly connect at your modem.

=item File transfers

It would be nice to implement C<[xyz]modem> like transfers between
two C<Device::Modem> objects connected with two modems.

=back


=head1 FAQ

There is a minimal FAQ document for this module online at
L<http://www.streppone.it/cosimo/work/perl/CPAN/Device-Modem/FAQ.html>

=head1 SUPPORT

Please feel free to contact me at my e-mail address L<cosimo@cpan.org>
for any information, to resolve problems you can encounter with this module
or for any kind of commercial support you may need.

=head1 AUTHOR

Cosimo Streppone, L<cosimo@cpan.org>

=head1 COPYRIGHT

(C) 2002-2003 Cosimo Streppone, L<cosimo@cpan.org>

This library is free software; you can only redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SEE ALSO

Device::SerialPort,
Win32::SerialPort,
Device::Gsm,
perl

=cut

