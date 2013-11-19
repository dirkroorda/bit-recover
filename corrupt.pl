#!/usr/bin/perl
use bytes;
use strict;
use warnings;
no warnings "uninitialized";
no strict "refs";
use Getopt::Long;

=head2 USAGE

	./corrupt.pl [-s] [-b nbits] [-l level | -n number] --data file*

Corrupts the file with (burst)bit errors.
If level is given, it is the desired number of (burst)bit errors per TB.
If number is given, it is the desired absolute number of bit errors.

The bit errors are generated at independently randomly chosen positions.

It is also possible to generate burst errors of length at most nbits.
A burst error is a sequence of identical bits that will overwrite a sequence of equal length in the input file.
The length of the burst is determined randomly and independently but stays below the maximum length.
The value of the burst (zeroes or ones) will be determined randomly.

=cut

my $verbose = 0;
my $corruptlevel = 100000;
my $unit = 8000000000000; # Terabyte
my $burstlength = 1;
my $corruptnumber;
my @datafiles = ();

my @kindrep = (
	'Error',
	'Warning',
	'Info',
	undef,
);

my ($nerrors, $datafile, $databitsize);

sub init {
	return GetOptions(
		'level|l=i' => \$corruptlevel,
		'unit|u=i' => \$unit, 
		'number|n=i' => \$corruptnumber,
		'burst|b=i' => \$burstlength,
		'verbose|v!' => \$verbose,
		'data=s{,}' => \@datafiles,
	);

	return 1;
}


sub dummy {
	1;
}

sub generate_errors {
	my $datafile = shift;

	my $databytesize = -s $datafile;
	$databitsize = 8 * $databytesize;
	msg(0, sprintf("%s has %d bits", $datafile, $databitsize));

	if (defined $corruptnumber and $corruptnumber) {
		$nerrors = $corruptnumber;
	}
	else {
		$nerrors = int($corruptlevel * $databitsize / $unit);
	}
	msg(0, sprintf("Need to generate %d burst (max %d bits long) errors for [%s]", $nerrors, $burstlength, $datafile));
	if ($nerrors == 0) {
		msg(-1, "Nothing to do");
		return 1;
	}

	if (!open(D, "+<:raw", $datafile)) {
		msg(-2, sprintf("Cannot write file [%s]", $datafile));
		return 0;
	}
	
	if (!open(R, "/dev/random")) {
		msg(-2, "Cannot get random numbers");
		return 0;
	}

#	generate the required number of random bit positions in the file
	my @positions = ();
	for (my $i = 0; $i < $nerrors; $i++) {
		my $posinfo = 0;
		read R, $posinfo, 8;
		my ($pos) = unpack("Q", $posinfo);

		my $lengthinfo = 0;
		read R, $lengthinfo, 8;
		my ($length) = unpack("Q", $lengthinfo);

		my $valueinfo = 0;
		read R, $valueinfo, 8;
		my ($value) = unpack("Q", $valueinfo);

		my $resultpos = $pos % $databitsize;
		my $resultlength = $length % $burstlength + 1;
		if ($resultpos + $resultlength > $databitsize) {
			$resultlength = $databitsize - $resultpos;
		}
		my $resultvalue = $value % 2;

		push @positions, [$resultpos, $resultlength, $resultvalue];
	}
	my @sortedpositions = sort {$a->[0] <=> $b->[0]} @positions;
	dummy();

#	mangle the bits at the generated positions in the data file
	
	my $mangled = 0;
	my $percentage = 0;
	my $npositions = scalar @sortedpositions;
	my $percentmangle = $npositions? 100 / $npositions : 100; 
	for my $item (@sortedpositions) {
		my ($bitstartpos, $length, $value) = @$item;
		msg(undef, sprintf("%11d%% %-10s at bitpos %30d length %2d value %d", $percentage, 'CORRUPT', $bitstartpos, $length, $value));
		$percentage += $percentmangle;

		my $bitendpos = $bitstartpos + $length - 1;
		my $bytestartpos = int($bitstartpos/8);
		my $byteendpos = int($bitendpos/8);
		my $nchangebytes = $byteendpos - $bytestartpos + 1;
		my $localbitstartpos = $bitstartpos % 8;
		my $newbytemask = pack "b*", sprintf("%s", 1 - $value) x ($nchangebytes * 8);
		for (my $i = 0; $i < $length - 1; $i++) {
			vec($newbytemask, $localbitstartpos + $i, 1) = $value
		}
		
		seek D, $bytestartpos, 0;
		my $oldbytes;
		read D, $oldbytes, $nchangebytes;
		my $newbytes;
		if ($value == 0) {
			$newbytes = $oldbytes & $newbytemask;
		}
		else {
			$newbytes = $oldbytes | $newbytemask;
		}
		if ($oldbytes ne $newbytes) {
			seek D, $bytestartpos, 0;
			print D $newbytes;
			$mangled++;
		}
	}
	close D;
	msg(1, sprintf("%-21s - %d changes from %d bursts in file [%s]", 'CORRUPT', $mangled, $nerrors, fname($datafile)));
	return 1;
}

sub fname {
	my $path = shift;
	$path =~ s/'//g;
	my ($fname) = $path =~ m/([^\/]*)$/;
	$fname =~ s/=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}//;
	return $fname;
}

sub msg {
	my ($kind, $msg) = @_;
	if (!defined $kind) {
		print STDERR $msg, "\r";
	}
	else {
		my $krep = $kindrep[$kind + 2];
		my $sep = ': ';
		if (!defined $krep) {
			$sep = '';
		}
		my $text = sprintf("%s%s%s\n",  $krep, $sep, $msg);
		if ($kind == 1) {
			print STDOUT $text;
		}
		if ($kind < 0 or $verbose) {
			print STDERR $text;
		}
	}
}

sub main {
	if (!init()) {
		return -1;
	}
	my $good = 1;
	for my $datafile (@datafiles) {
		if (!generate_errors($datafile)) {
			$good = 0;
		}
	}
	return $good;
}

exit !main();
