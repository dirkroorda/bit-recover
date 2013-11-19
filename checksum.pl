#!/usr/bin/perl
use bytes;
use strict;
use warnings;
no warnings "uninitialized";
no strict "refs";

use FileHandle;
use Getopt::Long qw(:config no_ignore_case);

use String::CRC qw(crc);
use Digest::CRC qw(crc32); #incredibly slow
use Digest::MD4 qw(md4);
use Digest::MD5 qw(md5);
use Digest::SHA qw(sha256);

=head1 DESCRIPTION

This tool is an instrument in bit preservation of (large) files.
It is estimated that if one reads 10 TB from disk, 1 bit will be in error.
Also, when 1 TB is stored for a year without touching it, some bits might
be damaged by random physical events such as radiation.

In order to bit-peserve large files for longer periods of time (years, decades),
it becomes important to guard against data loss.

While there is no profound solution to this problem, the following stratgegy
counts as best practice.

(i) Make several copies
(ii) Divide the file and their copies in chuncks and compute checksums of the chunks
(iii) periodically check checksums and restore damaged blocks from copies where the corresponding
block is undamaged.

Checksum.pl is a script to compute checksums for files, to verify checksums, and
to repair corrupted file by means of brute force searching, or if that is not feasible,
by restoring from backup copies, even if those are corrupt themselves. 
It works even when the checksums themselves are corrupt.

It al depends on the damage being not too big.

=head1 SYNOPSIS

	./checksum.pl [-s] [-m method] [-v | -c | -r[a|A] | -ec | -er | -dia] [file:kind=path]* file [backupfile] [origfile] [corruptfile]

This script can generate checksums, verify them, and perform repair and restore from backup.
The verification step produces a file with mismatches.
The repair and restore steps look at the file with mismatches and then try to find out how to repair
those mismatches. The result is writen to a file with instructions.
An execute step reads those instructions and executes them, actually changing the data file.
The checksum files are not modified. They can easily be recomputed again.

All intermediate files (also those with the generated checksums) are binary:
all data consists of fixed length strings, 64-bit integers, or fixed-size blocks of binary data.
All these files have a header, indicating the checksum method used, as well as the data block size and the
checksum length.

With arguments like file:kind=path you can overrule the locations and names (but not extensions) of all files that are read and written to.
The kind part must occur as key in the %files hash.

=head2 GENERATING

./checksum.pl file

Generates checksums for (large) files, block by block. The size of a block is configured to 1_000 bytes.
The main reason to keep it fairly small is to be able to do brute force guessing when a checksum is found not
to agree anymore with a datablock.

By generating many slight bit errors in the datablock as well as the checksum, and then searching for a valid
combination of datablock and checksum, we can be nearly completely sure that we have the original datablock and checksum
back.

The file with checksums has the same name as the input file, but with .chk appended to it. 

=head2 VERIFYING

./checksum.pl -v file

Verifies given checksums. It expects next to the input file a file.chk with checksums, in the format indicated
above. It then extracts from file each block as specified in file.chk, computes its checksum and compares it 
to the given checksum.

If there are checksum errors, references to the blocks in error are written to an error file, with name file.x .
This file contains records of mismatch information.
Such a record consists of just the block number, the given checksum, and the computed checksum.

If there are no errors, the file.x will not be present. If it existed, it will be deleted.

=head2 REPAIRING

./checksum.pl -c file

Looks at checksum mismatches. In every case, modifies checksum and corresponding blocks in many small ways,
until the combination matches again. Both block and checksum are dithered.
That means, a frame of at most n bits wide moves over the data, and inside the frame the bits are mangled
in all possible ways. The dither results of the checksum are stored in a hash.
The dithered blocks are not stored. They are generated on the fly, their checksum is computed, and quickly
tested against the hash of checksums. If there is a hit, it will be stored.
If there are no hits, repair is not possible by the current method. You might try further by increasing the
frame width, or by trying other kinds of variants of the block.
But maybe it is better to forget this method and try to restore from backup in such cases.
If there are multiple hits, that would be a weird situation. Maybe there has been intentional tampering.
The program will give clear warnings in these cases.

The repair instructions are written file.ri

=head2 RESTORING

./checksum.pl -r[a|A] file file-backup

Compares blocks and checksums of data and backup. The bit positions where they differ, will be varied among all
possibilities. The checksums are stored in a hash for easy lookup. Then the blocks will be generated on the fly.
So even if the backup is damaged, and even if the checksums are all damaged, it is still possible by brute force
search to find the original data back. If data and backup differ in less than 20 bits per block, there are only a million
possibilities per block to be searched.
If called with -rA only the blocks for which repair found multiple hits will be restored (not the ones without hits)
If called with -ra both the blocks for which repair found multiple hits and no hits will be restored

The restore instructions are written file.rib

=head2 EXECUTING

./checksum.pl -ec file
./checksum.pl -er file

Executes the repair resp. restore instructions in file.ri resp. file.rib
All information needed from the backup file is already in the instruction file, so the backup file itself is not 
needed here. The work has been done in the previous steps, this step only performs the write actions in the file.

=head2 DIAGNOSTICS

./checksum.pl -dia file backupfile origfile corruptfile

Creates a diagnostic report of the repair and restore instructions. It takes as second argument the backup file and as 
third argument the original file and as fourth argument the unrestored/unrepaired corrupted file.
It gives all info about the blocks which have not been restored correctly.
On the basis of this information it shows which instructions helped to correctly get the original back,
and which instructions were faulty.

=head2 AUTHOR

Dirk Roorda,
DANS
2013-03-29
dirk.roorda@dans.knaw.nl

=cut

=head2 CONFIGURATION

In order to compare performance between md5 and sha256 hashing we provide two standard configurations, which can be
invoked by the command line flag -m

	-m md5
	-m sha256

invoke the md5 and the sha256 checksum algorithms respectively.
The default parameter values for these methods are loaded. It remains possible to overrule these values
by means of additional flags on the command line.

The default checksum mode is sha256. 

=cut

my $checksum_mode = 'md5';

# blockbytesize   = byte size of a block in a file; keep it small, otherwise repair is not feasible
# checksumbitsize = size of a checksum in bits
# both values should be a power of 2

my $redundancy = 32;

my %config_checksum = (
	md5_16 => { # uses Digest::MD5, but takes only 2 bytes from its 16 bytes
		checksumbitsize => 16,
		method => 'md5_16',
	},
	md5_32 => { # uses Digest::MD5, but takes only 4 bytes from its 16 bytes
		checksumbitsize => 32,
		method => 'md5_32',
	},
	md5_64 => { # uses Digest::MD5, but takes only 8 bytes from its 16 bytes
		checksumbitsize => 64,
		method => 'md5_64',
	},
	crc32 => { # uses the String::CRC module
		checksumbitsize => 32,
		method => 'my_crc32',
	},
#	crc32d => { # uses the Digest::CRC module: pure perl, slow
#		checksumbitsize => 32,
#		method => 'my_crc32d',
#	},
	md4 => { # fast
		checksumbitsize => 128,
	},
	md5 => { # fast
		checksumbitsize => 128,
	},
	sha256 => { # twice as slow as MD5
		checksumbitsize => 256,
	},
);

sub my_crc32d {
	return pack "L", crc32($_[0]);
}

sub my_crc32 {
	return pack "L", crc($_[0]);
}

sub md5_16 {
	my $md5 = md5($_[0]);
	return substr($md5, 6, 1).substr($md5, 13, 1);
}

sub md5_32 {
	my $md5 = md5($_[0]);
	return substr($md5, 2, 1).substr($md5, 6, 1).substr($md5, 10, 1).substr($md5, 14, 1);
}

sub md5_64 {
	my $md5 = md5($_[0]);
	return substr($md5, 2, 1).substr($md5, 3, 1).substr($md5, 6, 1).substr($md5, 9, 1).substr($md5, 10, 1).substr($md5, 12, 1).substr($md5, 13, 1).substr($md5, 15, 1);
}

my $headerbytesize = 32;						# width of the header that is written to all binary generated files

my $limit_checksum_dist;						# accept at most this distance to checksums
my $dither_width_block;							# when dithering blocks, use a frame of this width
my $mask_size_block;							# if blocks differ more than this number of bits, no brute force repair will be attempted

my $check_diff_penalty = 1;						# see explanation below

my %bruteforce = (								# see explanation below; here are default values, can be overridden on command line
	repair => 100_000,
	restore => 1_000_000,
);

my @kindrep = (
	'Error',
	'Warning',
	'Info',
	undef,
);

=head2 Explanation

when measuring how close a "hit" is to the actual situation, the number of different bits in the checksums
and in the blocks are counted. However, differences in the checksum count much more than differences in the blocks.

Bit differences in the checksums are far less probable than bit differences in the blocks, because blocks are larger. 
Moreover, if checksums are very different, it is an indication of tampering: a new checksum has been computed for a slightly altered block.
So by default we multiply the checksum bit distance by the $data_checksum_ration.
In addition, you can configure to increase or decrease this effect by multiplying with the $check_diff_penalty which is by default 1.

We compare hits with the foreground file, not with the backup.
We want a hit that is closest to the foreground, since the foreground has been always under our control, and the backup has been far less in our control.

We want to keep the search effort constant for the different checksum methods. Depending on the blocksize determined by the checksum method, we can
set the search parameters in such a way that the prescribed number of search operations will be used.

=cut 

my @taskorder = qw(
	generate
	verify
	repair
	restore
	restore_ambi_no
	restore_ambi_only
	execute_repair
	execute_restore
	diag
);

my $verbose = 0;

my %datafile = (
	data	=> undef,
	backup	=> undef,
	orig	=> undef,
	corrupt	=> undef,
);

my %files = (
	log => {
		name => 'S{data}.log',
		header => 0,
		istext => 1,
	},
	data => {
		name => 'S{data}',
		header => 0,
		istext => 0,
	},
	databu => {
		name => 'S{backup}',
		header => 0,
		istext => 0,
	},
	dataorig => {
		name => 'S{orig}',
		header => 0,
		istext => 0,
	},
	datacorrupt => {
		name => 'S{corrupt}',
		header => 0,
		istext => 0,
	},
	checksum => {
		name => 'S{data}.chk',
		header => 1,
		istext => 0,
	},
	checksumbu => {
		name => 'S{backup}.chk',
		header => 1,
		istext => 0,
	},
	error => {
		name => 'S{data}.x',
		header => 1,
		istext => 0,
	},
	errortxt => {
		name => 'S{data}.x.txt',
		header => 1,
		istext => 1,
	},
	repair => {
		name => 'S{data}.ri',
		header => 1,
		istext => 0,
	},
	repairtxt => {
		name => 'S{data}.ri.txt',
		header => 1,
		istext => 1,
	},
	restore => {
		name => 'S{data}.rbi',
		header => 1,
		istext => 0,
	},
	restoretxt => {
		name => 'S{data}.rbi.txt',
		header => 1,
		istext => 1,
	},
	diag => {
		name => 'S{data}.diag.txt',
		header => 1,
		istext => 1,
	},
);

my $blockbytesize;				# if files have been generated with other block sizes, we can accomodate that
my $checksumbitsize;			# if files have been generated with other checksum sizes, we can accomodate that
my $checksumbytesize;			# we think of checksum sizes in bits
my $bruteforce;
my $checkarg;
my $subgood;

# data that is needed by many steps of the process

my ($nblock, $bytekind);
my ($lh, $dh, $dbh, $doh, $dch, $ch, $cbh, $eh, $eht, $rh, $rht, $rbh, $rbht, $xh, $diah);

my %task = ();

=head2 Command line

	./checksum.pl [-v] [-m method] [-t task]* [--conf kind=path]* --data kind=path [backupfile] [origfile] [corruptfile]

where 
	-v			verbose operation
	method		key of %config_checksum
	task		member of @taskorder

	conf:
		kind	key of %files
		path	will replace the name value in %files

	data	
		kind	key of %datafile
		path	path to a file on the file system

=cut

sub getcommandline {
	for my $task (@taskorder) {
		$task{$task}->{do} = 0;
	}
	$checkarg = 1;

	if (!GetOptions(
		'verbose|v!' => \$verbose,
		'redundancy|r=i' => \$redundancy,
		'bruteforce|bf=s%{,}' => \&checkarg,
		'method|m=s' => \&checkarg,
		'task|t=s@{,}' => \&checkarg,
		'data=s%{,}' => \&checkarg,
		'conf=s%{,}' => \&checkarg,
	)) {
		$checkarg = 0;
	}
	$subgood = 1;
	for my $kind (keys %files) {
		$files{$kind}->{name} =~ s/S\{([^\}]+)\}/subf($kind, $1)/sge;
	}
	if (!$subgood) {
		$checkarg = 0;
	}

	return $checkarg;
}

sub checkarg {
	my ($name, $value, $hashvalue) = @_;
	for (1) {
		if ($name eq 'method') {
			if (!exists $config_checksum{$value}) {
				msg(-2, sprintf("Unknown checksum mode [%s]. Allowed modes are [%s]", $value, join(",", (sort keys(%config_checksum)))));
				$checkarg = 0;
			}
			else {
				$checksum_mode = $value;
			}
			next;
		}
		if ($name eq 'task') {
			if (!exists $task{$value}) {
				msg(-2, sprintf("Unknown task [%s]. Allowed tasks are [%s]", $value, join(",", @taskorder)));
				$checkarg = 0;
			}
			else {
				$task{$value}->{do} = 1;
			}
			next;
		}
		if ($name eq 'bruteforce') {
			if (!exists $bruteforce{$value}) {
				msg(-2, sprintf("Unknown bruteforce parameter [%s]. Allowed parameters are [%s]", $value, join(",", sort(keys(%bruteforce)))));
				$checkarg = 0;
			}
			else {
				$bruteforce{$value} = $hashvalue;
			}
			next;
		}
		if ($name eq 'data') {
			if (!exists $datafile{$value}) {
				msg(-2, sprintf("Unknown kind of data file [%s]. Allowed kinds are [%s]", $value, join(",", sort(keys(%datafile)))));
				$checkarg = 0;
			}
			else {
				$datafile{$value} = $hashvalue;
			}
			next;
		}
		if ($name eq 'conf') {
			if (!exists $files{$value}) {
				msg(-2, sprintf("Unknown config setting [%s]. Allowed settings are [%s]", $value, join(",", sort(keys(%files)))));
				$checkarg = 0;
			}
			else {
				$files{$value}->{name} = $hashvalue;
			}
			next;
		}
	}
}

sub subf {
	my ($kind, $var) = @_;
	if (!exists $datafile{$var}) {
		msg(-2, sprintf("File specification [%s]: No such kind of datafile [%s]", $kind, $var));
		$subgood = 0;
		return 'S{'.$var.'}';
	}
	else {
		return $datafile{$var};
	}
}

sub setbruteforce {
	my $mode = shift;
	$bruteforce = $bruteforce{$mode};
	if (!$bruteforce) {
		msg(-2, "No bruteforce parameter specified for $mode");
		return 0;
	}
	return 1;
}

sub resolvem {
	my ($m1, $m2) = @_;
	if (exists $config_checksum{$m1} and exists $config_checksum{$m2}) {
		if ($m1 eq $m2) {
			return $m1;
		}
		else {
			return undef;
		}
	}
	if (exists $config_checksum{$m1} and !exists $config_checksum{$m2}) {
		return $m1;
	}
	if (exists $config_checksum{$m2} and !exists $config_checksum{$m1}) {
		return $m2;
	}
	return undef;
}

sub setchecksummode {
	my ($cmode, $givenchecksumbitsize, $givenblockbytesize)  = @_;
	my $contextrep = (defined $givenchecksumbitsize)?'File uses':'Default';
	my $info = $config_checksum{$cmode};
	if (!defined $info) {
		msg(-2, sprintf("%s unknown checksum mode [%s]. Allowed modes are [%s]", $contextrep, $cmode, join(",", (sort keys(%config_checksum)))));
		return 0;
	}
	else {
		$checksum_mode = $cmode;
	}

	if (defined $givenchecksumbitsize or defined $givenblockbytesize) {
		if (defined $givenchecksumbitsize and $givenchecksumbitsize == 0) {
			msg(-2, sprintf("Illegal checksumsize [%s] bits.", $givenchecksumbitsize));
			return 0;
		}
		$checksumbitsize = $givenchecksumbitsize;
		$checksumbytesize = $checksumbitsize / 8;
		if (defined $givenblockbytesize and $givenblockbytesize == 0) {
			msg(-2, sprintf("Illegal blocksize [%s] bytes.", $givenblockbytesize));
			return 0;
		}
		$blockbytesize = $givenblockbytesize;
		$redundancy = int($blockbytesize / $checksumbytesize);
	}
	else {
		$checksumbitsize = $info->{checksumbitsize};
		$checksumbytesize = $checksumbitsize / 8;
		$blockbytesize = int($checksumbitsize * $redundancy / 8);
	}

	determine_search_limits();

	my $givenmethod = $info->{method};
	if (!defined $givenmethod) {
		*chk = *$checksum_mode;
	}
	else {
		*chk = *$givenmethod;
	}
	msg(0, sprintf("%s checksum mode = %s (%d bits); blocks have (%d bytes); redundancy = 1 / %d", $contextrep, $checksum_mode, $checksumbitsize, $blockbytesize, $redundancy));
	return 1;
}

sub determine_search_limits {
	my $blockbitsize = $blockbytesize * 8;
	my $standard_step_cost = 4096; # number of bits in 1/2 Kbytes, the blocksize corresponding to MD5 with redundancy 32.
	my $this_step_cost = $blockbitsize / $standard_step_cost;

	for my $item (
		['repair', 'block', \$dither_width_block],
		['restore', 'block', \$mask_size_block],
	) {
		my ($step, $kind, $var) = @$item;
		my $param = 0;
		my $noperations = 1;
		while ($noperations < $bruteforce{$step}) {
			$param++;
			if ($step eq 'repair') {
				$noperations = int((1 << ($param - 1)) * $blockbitsize * $this_step_cost);
			}
			elsif ($step eq 'restore') {
				$noperations = int((1 << $param) * $this_step_cost);
			}
		}
		$$var = $param;
	}
	$limit_checksum_dist = $checksumbitsize >> 4;
}

sub init {
	STDOUT->autoflush(1); # when called by an other perl script, output messages will become available to the caller immediately

	if (!getcommandline) {
		return 0;
	}

	$lh = openwrite('log', 1);
	if (!$lh) {
		return 0;
	}
	if (!setchecksummode($checksum_mode)) {
		return 0;
	}

	return 1;
}

sub getpath {
	return $files{$_[0]}->{name};
}

=head2 Binary files and headers

Every binary non-data file we read, is a file generated by this program. Such a file has a header.
It will be read and written by the following two functions.
It has the format

	a8 a8 L L L L

where

	a8 is arbitrary binary data of 8 bytes. Reserved for a string indicating the checksum method
	a8 is arbitrary binary data of 8 bytes. Reserved for a string indicating the checksum method
	L is a long integer (32 bits = 4 bytes), indicating the checksum size
	L is a long integer (32 bits = 4 bytes), indicating the checksum size
	L is a long integer (32 bits = 4 bytes), indicating the block size
	L is a long integer (32 bits = 4 bytes), indicating the block size

All together the header is 32 bytes = 256 bits

The header could be damaged. We assume the checksum size and the block size are powers of two.
If one of them does not appear a power of two, choose the other. If both are not powers of two, we are stuck.
If both are powers of two but different, we are also stuck.
Likewise, we choose between the values encountered for the checksummethod.

=cut

sub readheader {
	my $fh = shift;
	my $header = "";
	my $nread = read $fh, $header, $headerbytesize;
	if ($nread < $headerbytesize) {
		msg(-2, "Could not read header");
		return 0;
	}
	my ($method, $methodr, $thischecksumbitsize, $thischecksumbitsizer, $thisblockbytesize, $thisblockbytesizer) = unpack("a8 a8 L L L L", $header);
	$method =~ s/\000+$//;
	$methodr =~ s/\000+$//;
	my $goodmethod = resolvem($method, $methodr);
	my $goodchecksumbitsize = resolve($thischecksumbitsize, $thischecksumbitsizer);
	my $goodblockbytesize = resolve($thisblockbytesize, $thisblockbytesizer);
	if (!defined $goodmethod) {
		msg(-2, sprintf("Damaged header, cannot be repaired. Checksum method is %s versus %s.", $method, $methodr));
		return 0;
	}
	if (!defined $thischecksumbitsize or !defined $thisblockbytesize) {
		msg(-2, sprintf("Damaged header, cannot be repaired. Checksum bit size is %d versus %d. Block byte size is %d versus %d.", $thischecksumbitsize, $thischecksumbitsizer, $thisblockbytesize, $thisblockbytesizer));
		return 0;
	}
	if ($goodmethod ne $method or $goodmethod ne $methodr) {
		msg(-1, sprintf("Damaged header, has been repaired. Checksum methods found: %s and %s.  Chosen %s. ", $method, $methodr, $goodmethod));
		$method = $goodmethod;
	}
	if ($goodchecksumbitsize != $thischecksumbitsize) {
		msg(-1, sprintf("Damaged header, has been repaired. Checksum bit size was %d and is now %d. ", $thischecksumbitsize, $goodchecksumbitsize));
		$thischecksumbitsize = $goodchecksumbitsize;
	}
	if ($goodblockbytesize != $thisblockbytesize) {
		msg(-1, sprintf("Damaged header, has been repaired. Block byte size was %d and is now %d. ", $thisblockbytesize, $goodblockbytesize));
		$thisblockbytesize = $goodblockbytesize;
	}
	if (!setchecksummode($method, $thischecksumbitsize, $thisblockbytesize)) {
		return 0;
	}
	msg(0, sprintf("Appears to use block size [%d] bytes and checksum size [%d] bits", $blockbytesize, $checksumbitsize));
	return 1;
}

sub writeheader {
	my $fh = shift;
	my $istext = shift;
	if ($istext) {
		printf $fh "%s (%d bits) [blocksize = %d bytes] redundancy = 1 / %d\n", $checksum_mode, $checksumbitsize, $blockbytesize, $redundancy;
	}
	else {
		print $fh pack("a8 a8 L L L L", $checksum_mode, $checksum_mode, $checksumbitsize, $checksumbitsize, $blockbytesize, $blockbytesize);
	}
	msg(0, sprintf("Set to use block size [%d] bytes and checksum size [%d] bits", $blockbytesize, $checksumbitsize));
	return 1;
}

=head2 Reading and Writing files

Opens files for reading, writing, and read-writing.
Uses the specification created in the init() function.
Returns a file handle in case of succes.
The file handle is meant ot be stored in global variables.
So more than one routine can easily read and write the same file.

getbytes(filehandle, pos, length) reads length bytes starting at position pos from open filehandle.

If pos is undefined, the position is the current position. If it is defined, a seek will be performed.
If there are errors, returns undef.
If it cannot read the specified length number of bytes, it gives as much as it can, without warning.
The caller can check the length of the returned string.

=cut

sub openread {
	my $kind = shift;
	my $rw = shift;
	my $openmode = "<";
	my $msg = '';
	if ($rw) {
		$openmode = "+<";
		$msg = " and writing";
	}
	my $info = $files{$kind};
	my $name = getpath($kind);
	my $fh = FileHandle->new;
	if (!$fh->open("$openmode $name")) {
		msg(-2, sprintf("Cannot read (%s)-file [%s]", $kind, $name));
		return 0;
	}
	binmode $fh;
	msg(0, sprintf("(%s)-file [%s] opened for reading$msg", $kind, $name));
	my $good = 1;
	if ($info->{header}) {
		$good = readheader($fh);
	}
	if ($kind eq 'data') {
		my $filesize = -s $name;
		$info->{size} = $filesize;
		if ($filesize == 0) {
			msg(-1, sprintf("(%s)-file is empty", $kind));
			return 0;
		}
		msg(0, sprintf("(%s)-file has size %d bytes", $kind, $filesize));
	}
	if ($good) {
		return $fh;
	}
	else {
		return 0;
	}
}

sub openwrite {
	my $kind = shift;
	my $append = shift;
	my $openmode = ">";
	my $msg = 'writing';
	if ($append) {
		$openmode = ">>";
		$msg = "appending";
	}
	my $info = $files{$kind};
	my $name = getpath($kind);
	my $fh = FileHandle->new;
	if (!$fh->open("$openmode $name")) {
		msg(-2, sprintf("Cannot write (%s)-file [%s]", $kind, $name));
		return 0;
	}
	binmode $fh;
	if ($kind ne 'log') {
		msg(0, sprintf("(%s)-file [%s] opened for $msg", $kind, $name));
	}
	my $good = 1;
	if ($info->{header}) {
		$good = writeheader($fh, $info->{istext});
	}
	if ($good) {
		return $fh;
	}
	else {
		return 0;
	}
}

sub getbytes {
	my ($fh, $pos, $length) = @_;
	if (defined $pos) {
		my $success = seek $fh, $pos, 0;
		if (!$success) {
			msg(-2, sprintf("Cannot go to position [%d] in (%s)-file", $pos, $bytekind));
			return undef;
		}
	}
	my $chunk;
	my $nread = read $fh, $chunk, $length;
	if (!defined $nread) {
		msg(-2, sprintf("Cannot read [%d] bytes for block [%d] in (%s)-file", $length, $nblock, $bytekind));
		return undef;
	}
	if (!$nread) {
		return "";
	}
	return $chunk;
}

=head2 GENERATE

This function implements a main step: Generate Checksums

=cut

sub task_generate {
	msg(0, sprintf("Creating %s-s of length [%d] bits with blocksize [%d] bytes; redundancy = 1 / %d", $checksum_mode, $checksumbitsize, $blockbytesize, $redundancy));
	$dh = openread('data');
	if (!$dh) {
		return 0;
	}
	$ch = openwrite('checksum');
	if (!$ch) {
		return 0;
	}
	my $datafile = getpath('data');
	my $checksumfile = getpath('checksum');

	my $good = 1;
	my $percentage = 0;
	$nblock = -1;
	$bytekind = 'data';

	my $chunk = "x";
	my $percentblock = $files{data}->{size}? 100 * $blockbytesize / $files{data}->{size} : 100;
	while ($chunk ne '') {
		$nblock++;
		msg(undef, sprintf("%11d%% %-8s %3d:%-9s- block %20d", $percentage, 'GENERATE', $redundancy, $checksum_mode, $nblock));
		$chunk = getbytes($dh, undef, $blockbytesize);
		if (!defined $chunk) {
			$good = 0;
			next;
		}
		if ($chunk eq '') {
			next;
		}
		$percentage += $percentblock;
		print $ch chk($chunk);
	}
	close $dh;
	close $ch;
	msg(1, sprintf("%-8s %3d:%-8s - %d in [%s] from [%s]%s", 'GENERATE', $redundancy, $checksum_mode, $nblock, 'checksumfile', 'datafile', ' ' x 30));
	return $good;
}

=head2 VERIFY

This function implements a main step: Verify Checksums

=cut

sub task_verify {
	msg(0, sprintf("Verifying %s-s", $checksum_mode));
	$dh = openread('data');
	if (!$dh) {
		return 0;
	}
	$ch = openread('checksum');
	if (!$ch) {
		return 0;
	}
	msg(0, sprintf("Checksums of length [%d] bits with blocksize [%d] bytes", $checksumbitsize, $blockbytesize));
	$eh = openwrite('error');
	if (!$eh) {
		return 0;
	}
	$eht = openwrite('errortxt');
	if (!$eht) {
		return 0;
	}
	my $datafile = getpath('data');
	my $errorfile = getpath('error');

	my $good = 1;
	my $goodblocks = 0;
	my $percentage = 0;
	my $written = 0;
	$nblock = -1;

	my $percentblock = $files{data}->{size}? 100 * $blockbytesize / $files{data}->{size} : 100;
	my $checksum = "x";
	while ($checksum ne '') {
		$nblock++;
		$bytekind = 'checksum';
		$checksum = getbytes($ch, undef, $checksumbytesize);
		if (!defined $checksum) {
			$good = 0;
			next;
		}
		if ($checksum eq '') {
			next;
		}
		$percentage += $percentblock;

		msg(undef, sprintf("%11d%% %-8s %3d:%-9s- [%d ok, %d fail] block %20d", $percentage, 'VERIFY', $redundancy, $checksum_mode, $goodblocks, $written, $nblock));
		$bytekind = 'data';
		my $chunk = getbytes($dh, undef, $blockbytesize);
		if (!defined $chunk) {
			$good = 0;
			next;
		}

		my $cchecksum = chk($chunk);  
		if ($cchecksum ne $checksum) {
			print $eh pack(sprintf("Q a%d a%d", $checksumbytesize, $checksumbytesize), $nblock, $checksum, $cchecksum);
			printf $eht "block %20d: checksumdiff=%s\n", $nblock, diffbitstring($checksum, $cchecksum);
			$written++;
		}
		else {
			$goodblocks++;
		}
	}
	close $dh;
	close $ch;
	close $eh;
	close $eht;

	my $errorblocks = $nblock - $goodblocks;
	msg(1, sprintf("%-8s %3d:%-8s - %d ok, %d faulty, total %d in [%s]%s", 'VERIFY', $redundancy, $checksum_mode, $goodblocks, $written, $nblock, 'datafile', ' ' x 30));
	msg(0, sprintf("%-8s %3d:%-8s - %d faults written to [%s]", 'VERIFY', $redundancy, $checksum_mode, $written, $errorfile));

	return $good;
}

=head2 REPAIR

This function implements a main step: Repair on the basis of Checksums, without using backup

=cut

sub task_repair {
	if (!setbruteforce('repair')) {
		return 0;
	}
	my $good = 1;
	my $percentage = 0;
	my $written = 0;
	my $errorfile = getpath('error');
	msg(0, sprintf("Correcting identified errors in blocks and %s-s listed in (error)-file [%s]", $checksum_mode, $errorfile));
	$eh = openread('error');
	if (!$eh) {
		return 0;
	}
	msg(1, sprintf("%-8s %3d:%-8s - block frame width %d, max checksum distance %d, brute force %d", 'REPAIR', $redundancy, $checksum_mode, $dither_width_block, $limit_checksum_dist, $bruteforce));

	my @errorblocks = ();
	my $errinfo = 'x';
	while ($errinfo ne '') {
		$bytekind = 'error-info';
		$errinfo = getbytes($eh, undef, 8 + 2 * $checksumbytesize);
		if (!defined $errinfo) {
			$good = 0;
			next;
		}
		if ($errinfo eq '') {
			next;
		}
		my @errordata = unpack(sprintf("Q a%d a%d", $checksumbytesize, $checksumbytesize), $errinfo);
		push @errorblocks, \@errordata;
	}
	close $eh;

	if (!scalar(@errorblocks)) {
		msg(-1, "Nothing to do");
	}
	my $repairedblocks = 0;
	my $ambiblocks = 0;
	my $unrepairedblocks = 0;
	my $percentblock = scalar(@errorblocks)?100 / scalar(@errorblocks):100;
	my $ambival = 0;
	msg(0, sprintf("%d blocks to repair", scalar(@errorblocks)));
	$dh = openread('data');
	if (!$dh) {
		return 0;
	}
	$rh = openwrite('repair');
	if (!$rh) {
		return 0;
	}
	$rht = openwrite('repairtxt');
	if (!$rht) {
		return 0;
	}

	for my $errorblock (@errorblocks) {
		my ($theblock, $checksum_given, $checksum_computed) = @$errorblock;
		msg(undef, sprintf("%8s%3d%% %-8s %3d:%-9s- [%d ok (%d ambi), %d fail, ambival %d] block [%d]     ", ' ', $percentage, 'REPAIR', $redundancy, $checksum_mode, $repairedblocks, $ambiblocks, $unrepairedblocks, $ambival, $theblock));
		$percentage += $percentblock;
		my $block = getbytes($dh, $theblock * $blockbytesize, $blockbytesize);
		if (!defined $block) {
			msg(-2, sprintf("Cannot read block %20d from (data)-file", $theblock));
			$unrepairedblocks++;
			$good = 0;
			next;
		}
		my $status = repairblock($theblock, $block, $checksum_given);
		if (!$status) {
			$unrepairedblocks++;
		}
		elsif ($status < 0) {
			$repairedblocks++;
			$ambiblocks++;
			$ambival -= $status;
		}
		else {
			$repairedblocks++;
		}
	}
	close $dh;
	close $rh;
	close $rht;

	msg(1, sprintf("%-8s %3d:%-8s - %d ok (%d ambi), %d failure, total %d, ambival %d in [%s]%s", 'REPAIR', $redundancy, $checksum_mode, $repairedblocks, $ambiblocks, $unrepairedblocks, scalar(@errorblocks), $ambival, 'errorfile', ' ' x 30));

	msg(0, sprintf("%d block repair instructions written to (repair)-file %s", $repairedblocks, getpath('repair')));
	msg(0, sprintf("%d block unrepair info written to (repair)-file %s", $unrepairedblocks, getpath('repair')));

	return $good;
}

=head2 RESTORE

This function implements a main step: Restore using backup, uses also checksums to overcome errors in backup

=cut

sub task_restore {
	return restore_engine(1);
}

sub task_restore_ambi_no {
	return restore_engine(0);
}

sub task_restore_ambi_only {
	return restore_engine(-1);
}

sub restore_engine {
	my $ambigu = shift;
	if (!setbruteforce('restore')) {
		return 0;
	}
	my $percentage = 0;
	my $written = 0;
	my $repairfile = getpath('repair');
	msg(0, sprintf("Restoring from backup identified repair-failures in blocks and %s-s listed in (repair)-file [%s]", $checksum_mode, $repairfile));
	$rh = openread('repair');
	if (!$rh) {
		return 0;
	}
	msg(1, sprintf("%-8s %3d:%-8s - block mask width %d, max checksum distance %d, brute force %d", 'RESTORE', $redundancy, $checksum_mode, $mask_size_block, $limit_checksum_dist, $bruteforce));

	my @restoreblocks = ();
	my $repairinfoheader = 'x';
	my @actions = ();
	my $good = 1;
	while ($repairinfoheader ne '') {
		$bytekind = 'repair-info';
		$repairinfoheader = getbytes($rh, undef, 8 + 8 + 8 + 8 + 8);
		if (!defined $repairinfoheader) {
			$good = 0;
			next;
		}
		if ($repairinfoheader eq '') {
			next;
		}
		my ($kind, $theblock, $thisblockbytesize, $dist, $ambival) = unpack("a8 Q Q Q Q", $repairinfoheader);
		my $repairinfodata = getbytes($rh, undef, $checksumbytesize + $thisblockbytesize);
		$kind =~ s/\000+$//;
		my $condition = $kind eq 'NOHITS' || $kind eq 'BLENGTH?' || $kind eq 'CLENGTH?' || $kind eq 'TAMPER';
		if ($ambigu == 1) {
			$condition = $condition || $kind eq 'HIT?';
		}
		elsif ($ambigu == -1) {
			$condition = $kind eq 'HIT?';
		}
		if ($condition) {
			my ($thischecksum, $thisblock) = unpack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $repairinfodata);
			push @restoreblocks, [$theblock, $thischecksum, $thisblock];
		}
	}
	close $rh;


	if (!scalar(@restoreblocks)) {
		msg(-1, "Nothing to do");
	}
	my $restoredblocks = 0;
	my $ambiblocks = 0;
	my $unrestoredblocks = 0;
	my $percentblock = scalar(@restoreblocks)?100 / scalar(@restoreblocks):100;
	my $ambival = 0;
	msg(0, sprintf("%d blocks to restore", scalar(@restoreblocks)));
	$dbh = openread('databu');
	if (!$dbh) {
		return 0;
	}
	$cbh = openread('checksumbu');
	if (!$cbh) {
		return 0;
	}
	$rbh = openwrite('restore');
	if (!$rbh) {
		return 0;
	}
	$rbht = openwrite('restoretxt');
	if (!$rbht) {
		return 0;
	}

	for my $restoreblock (@restoreblocks) {
		my ($theblock, $checksum, $block) = @$restoreblock;
		$percentage += $percentblock;
		msg(undef, sprintf("%11d%% %-8s %3d:%-9s- [%d ok (%d ambi), %d fail, ambival %d] block [%d]", $percentage, 'RESTORE', $redundancy, $checksum_mode, $restoredblocks, $ambiblocks, $unrestoredblocks, $ambival, $theblock));
		my $blockbu = getbytes($dbh, $theblock * $blockbytesize, $blockbytesize);
		my $checksumbu = getbytes($cbh, $headerbytesize + $theblock * $checksumbytesize, $checksumbytesize);
		my $thisgood = 1;
		if (!defined $blockbu) {
			$thisgood = 0;
		}
		if (!defined $checksumbu) {
			$thisgood = 0;
		}
		if (!$thisgood) {
			$unrestoredblocks++;
			$good = 0;
			next;
		}
		my $status = restoreblock($theblock, $block, $blockbu, $checksum, $checksumbu);
		if (!$status) {
			$unrestoredblocks++;
		}
		elsif ($status < 0) {
			$restoredblocks++;
			$ambiblocks++;
			$ambival -= $status;
		}
		else {
			$restoredblocks++;
		}
	}
	close $dbh;
	close $cbh;
	close $rbh;
	close $rbht;

	msg(1, sprintf("%-8s %3d:%-8s - %d ok (%d ambi), %d failure, total %d, ambival %d in [%s]%s", 'RESTORE', $redundancy, $checksum_mode, $restoredblocks, $ambiblocks, $unrestoredblocks, scalar(@restoreblocks), $ambival, 'repairfile', ' ' x 30));

	msg(0, sprintf("%d block restore instructions written to (restore)-file %s", $restoredblocks, getpath('restore')));
	msg(0, sprintf("%d block unrestore info written to (restore)-file %s", $unrestoredblocks, getpath('restore')));

	return $good;
}

=head2 EXECUTE

This function implements a main step: Execute repair/restore instructions

=cut

sub task_execute_repair {
	return execute_engine('repair');
}

sub task_execute_restore {
	return execute_engine('restore');
}

sub execute_engine {
	my $mode = shift;

	$xh = openread($mode);
	if (!$xh) {
		return 0;
	}

	my $actionfile = getpath($mode);

	my $repairinfoheader = 'x';
	my @actions = ();
	my $good = 1;
	while ($repairinfoheader ne '') {
		$bytekind = 'repair-info';
		$repairinfoheader = getbytes($xh, undef, 8 + 8 + 8 + 8 + 8);
		if (!defined $repairinfoheader) {
			$good = 0;
			next;
		}
		if ($repairinfoheader eq '') {
			next;
		}
		my ($kind, $theblock, $thisblockbytesize, $dist, $ambival) = unpack("a8 Q Q Q Q", $repairinfoheader);
		my $repairinfodata = getbytes($xh, undef, $checksumbytesize + $thisblockbytesize);
		$kind =~ s/\000+$//;
		my $msgkind = 0;
		my $addaction = 1;
		if ($kind eq 'HIT' or $kind eq 'NOHITS' or $kind eq 'BLENGTH?' or $kind eq 'CLENGTH?') {
			$msgkind = 0;
			$addaction = 0;
		}
		elsif ($kind eq 'TAMPER?') {
			$msgkind = -1;
			$addaction = 0;
		}
		if ($msgkind != 0) {
			msg($msgkind, sprintf("%8s => block %20d of size %d bytes at distance %d", $kind, $theblock, $thisblockbytesize, $dist));
		}
		if ($addaction) {
			my ($thischecksum, $thisblock) = unpack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $repairinfodata);
			if ($kind eq 'HIT?' or $kind eq 'HIT!') {
				push @actions, [$theblock, $thischecksum, $thisblock];
			}
		}
	}
	close $xh;

	my $nactions = scalar @actions;

	if (!$nactions) {
		msg(0, "No actions found. Nothing to do");
	}
	else {
		msg(0, sprintf("Going to do %d actions.", $nactions));
	}

	my $percentage = 0;
	my $percentaction = $nactions?100 / $nactions:100;

	$dh = openread('data', 1);
	if (!$dh) {
		return 0;
	}
	my $nsuccess = 0;
	my $nfail = 0;
	for my $action (@actions) {
		my ($theblock, $thechecksum, $block) = @$action;
		$percentage += $percentaction;
		msg(undef, sprintf("%11d%% %-8s %3d:%-9s- [%d ok, %d fail] block %20d    ", $percentage, 'EXECUTE', $redundancy, $checksum_mode, $nsuccess, $nfail, $theblock));
		my $pos = $theblock * $blockbytesize;
		$bytekind = 'data';
		my $success = seek $dh, $pos, 0;
		if (!$success) {
			msg(-2, sprintf("Cannot go to position [%d] in (%s)-file", $pos, $bytekind));
			$good = 0;
			$nfail++;
			next;
		}
		print $dh $block;
		$nsuccess++;
	}
	msg(1, sprintf("%-8s %3d:%-8s - %d ok and %d failure, total %d in [%s]%s", 'EXECUTE', $redundancy, $checksum_mode, $nsuccess, $nfail, scalar(@actions), 'actionfile', ' ' x 30));
	close $dh;
	return $good;
}

=head2 DIAGNOSTICS

This function implements a main step: Generate a diagnostic report

=cut

sub task_diag {
	my $good = 1;
	my %suspects = ();
	my @problems = ();
	my ($nsuspects, $nproblems);

	for (1) {

# investigate repair instructions in repair and restore files

		my $repairfile = getpath('repair');
		my $restorefile = getpath('restore');
		msg(0, sprintf("Investigating repair instructions in blocks listed in (repair)-file [%s] and (restore)-file [%s]", $repairfile, $restorefile));
		$rh = openread('repair');
		if (!$rh) {
			$good = 0;
			next;
		}
		$rbh = openread('restore');
		if (!$rbh) {
			$good = 0;
			next;
		}
		$diah = openwrite('diag');
		if (!$diah) {
			$good = 0;
			next;
		}
		%suspects = ();
		for my $item (
			[$rh, 'repair'],
			[$rbh, 'restore'],
		) {
			my ($xh, $step) = @$item;;

			my $infoheader = 'x';
			while ($infoheader ne '') {
				$bytekind = "$step-info";
				$infoheader = getbytes($xh, undef, 8 + 8 + 8 + 8 + 8);
				if (!defined $infoheader) {
					$good = 0;
					next;
				}
				if ($infoheader eq '') {
					next;
				}
				my ($kind, $theblock, $thisblockbytesize, $dist, $ambival) = unpack("a8 Q Q Q Q", $infoheader);
				my $infodata = getbytes($xh, undef, $checksumbytesize + $thisblockbytesize);
				my ($thischecksum, $thisblock) = unpack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $infodata);
				$kind =~ s/\000+$//;
				if ($kind eq 'HIT!' or $kind eq 'HIT?' or $kind eq 'NOHITS') {
					$suspects{$theblock}->{$step} = [$kind, $thischecksum, $thisblock, $dist, $ambival]; 
				}
			}
		}
		close $rh;
		close $rbh;

		if (!$good) {
			next;
		}

		$nsuspects = scalar keys %suspects;
		@problems = ();

		msg(1, sprintf("%-8s %3d:%-8s - %d blocks touched", 'DIAG', $redundancy, $checksum_mode, $nsuspects));
		if (!$nsuspects) {
			printf $diah "I: no blocks have been repaired or restored\n";
			next;
		}
		msg(0, sprintf("Investigating instructions for %d blocks", $nsuspects));
		$doh = openread('dataorig');
		if (!$doh) {
			$good = 0;
			next;
		}
		for my $theblock (sort {$a <=> $b} keys %suspects) {
			my $info = $suspects{$theblock};
			my $compareinfo = $info->{restore};
			if (!defined $compareinfo) {
				$compareinfo = $info->{repair};
			}
			my $blockcurrent = $compareinfo->[2];
			my $blockorig = getbytes($doh, $theblock * $blockbytesize, $blockbytesize);
			if (!defined $blockorig) {
				msg(-2, sprintf("Cannot read block %20d from (%s)-file", 'original', $theblock));
				$good = 0;
				printf $diah, "E[%d]: error reading from original file\n", $theblock;
				next;
			}
			if ($blockcurrent ne $blockorig) {
				push @problems, [$theblock, $info, $blockorig, $blockcurrent];
			}
		}
		close $doh;

		$nproblems = scalar @problems;
		msg(1, sprintf("%-8s %3d:%-8s - %d blocks incorrect", 'DIAG', $redundancy, $checksum_mode, $nproblems));
		if (!$nproblems) {
			printf $diah "I: all modified blocks are correct\n";
			next;
		}
		msg(0, sprintf("Investigating data for %d incorrect blocks", $nproblems));
		$eh = openread('error');
		if (!$eh) {
			return 0;
		}
		$dbh = openread('databu');
		if (!$dbh) {
			$good = 0;
			next;
		}
		$dch = openread('datacorrupt');
		if (!$dch) {
			$good = 0;
			next;
		}
		my %errorblocks = ();
		my $errinfo = 'x';
		while ($errinfo ne '') {
			$bytekind = 'error-info';
			$errinfo = getbytes($eh, undef, 8 + 2 * $checksumbytesize);
			if (!defined $errinfo) {
				$good = 0;
				next;
			}
			if ($errinfo eq '') {
				next;
			}
			my ($theblock, $checksumgiven, $checksumcomputed) = unpack(sprintf("Q a%d a%d", $checksumbytesize, $checksumbytesize), $errinfo);
			$errorblocks{$theblock} = [$checksumgiven, $checksumcomputed];
		}
		close $eh;

		for my $problem (@problems) {
			my %blockdata = ();
			my %checksumdata = ();
			my %distdata = ();
			my %kinddata = ();
			my %ambidata = ();
			my ($theblock, $info, $blockorig, $blockrenewed) = @$problem;

			$blockdata{data} = $blockrenewed;
			$checksumdata{data} = chk($blockdata{data});
			$blockdata{original} = $blockorig;
			$checksumdata{original} = chk($blockdata{original});

			if (defined $info->{repair}) {
				$blockdata{repair} = $info->{repair}->[2];
				$checksumdata{repair} = $info->{repair}->[1];
				$distdata{repair} = $info->{repair}->[3];
				$kinddata{repair} = $info->{repair}->[0];
				$ambidata{repair} = $info->{repair}->[4];
			}
			if (defined $info->{restore}) {
				$blockdata{restore} = $info->{restore}->[2];
				$checksumdata{restore} = $info->{restore}->[1];
				$distdata{restore} = $info->{restore}->[3];
				$kinddata{restore} = $info->{repair}->[0];
				$ambidata{restore} = $info->{repair}->[4];
			}
			my $thisgood = 1;
			for my $item (
				['backup', $dbh], 
				['corrupt', $dch], 
			) {
				my ($kind, $fileh) = @$item;
				$blockdata{$kind} = getbytes($fileh, $theblock * $blockbytesize, $blockbytesize);
				if (!defined $blockdata{$kind}) {
					msg(-2, sprintf("Cannot read block %20d from (%s)-file", $kind, $theblock));
					$thisgood = 0;
					printf $diah, "E[%d]: error reading from %s file\n", $kind, $theblock;
				}
			}
			$checksumdata{corrupt} = $errorblocks{$theblock}->[0];
			if (!$thisgood) {
				$good = 0;
				next;
			}

# compose the diagnostic information
			printf $diah "[Block %d]\n", $theblock;
			for my $item (
				['original', 'corrupt'],
				['corrupt', 'repair'],
				['repair', 'restore'],
				['original', 'data'],
			) {
				my ($kind1, $kind2) = @$item;
				if (!defined $blockdata{$kind1} or !defined $blockdata{$kind2}) {
					next;
				}
				print $diah "[$kind1 versus $kind2]";
				my $diagstring = "";
				my $datastring = "";
				if ($checksumdata{$kind1} eq $checksumdata{$kind2}) {
					$diagstring .= " #=";
					$datastring .= '';
				}
				else {
					$diagstring .= " #~";
					$datastring .= "checksum: " . pretty($checksumdata{$kind1} ^ $checksumdata{$kind2}) . "\n";
				}
				if ($blockdata{$kind1} eq $blockdata{$kind2}) {
					$diagstring .= " []=";
					$datastring .= '';
				}
				else {
					$diagstring .= " []~";
					$datastring .= "block:    " . pretty($blockdata{$kind1} ^ $blockdata{$kind2}) . "\n";
				}
				if (defined $kinddata{$kind2}) {
					$diagstring .= sprintf " %s", $kinddata{$kind2};
				}
				if (defined $distdata{$kind2}) {
					$diagstring .= sprintf " dist=%d", $distdata{$kind2};
				}
				if (defined $ambidata{$kind2}) {
					$diagstring .= sprintf " ambival=%d", $ambidata{$kind2};
				}
				if ($kind2 eq 'repair') {
					$diagstring .= sprintf " block frame %d bits, max checksum dist %d bits", $dither_width_block, $limit_checksum_dist;  
				}
				elsif ($kind2 eq 'restore') {
					$diagstring .= sprintf " block mask %d bits, max checksum dist %d bits", $mask_size_block, $limit_checksum_dist;  
				}
				$diagstring .= "\n";
				print $diah $diagstring, $datastring;
			}
		}
	}
	close $dbh;
	close $dch;
	close $diah;

	msg(1, sprintf("%-8s %3d:%-8s - %d problems diagnosed", 'DIAG', $redundancy, $checksum_mode, $nproblems));
	msg(0, sprintf("diagnostic report written to (diag)-file %s", getpath('diag')));

	return $good;
}

=head2 REPAIR BLOCK

This function implements a main step: Repair a single block
We apply ditherings progressively, in rounds corresponding to the frame length n of the dithering.
We start with n = 0, then n = 1 and so on.
So the smaller disturbances will be checked first, and we assume that bigger disturbances do not compete with smaller ones.
If there are hits in a round, the next rounds will be skipped.

=cut

sub repairblock {
	my ($theblock, $block, $checksum) = @_;

	my $nblockbytes = length $block;
	my $nblockbits = $nblockbytes * 8;
	my $dither_width = $dither_width_block;
	if ($nblockbits < $dither_width) {
		$dither_width = $nblockbits;
	}
	my @hits = ();
	my $ops = 0;
	my $stop = 0;
	for (my $nbits = 0; $nbits <= $dither_width; $nbits++) {
		my $found = 0;
		if ($nbits == 0) {
			msg(undef, sprintf("%1d:%5d", 0, int($ops/1000)));
			$ops++;
			my $thischeck = chk($block);
			if (bitdist($thischeck, $checksum) <= $limit_checksum_dist) {
				push @hits, [$block, $thischeck];
				$found = 1;
				last;
			}
		}
		else {
			for my $dbits (gen_dither_frames($nbits)) {
				for (my $i = 0; $i < $nblockbits - $nbits + 1; $i++) {
					$ops++;
					if ($ops > $bruteforce) {
						$stop = 1;
						last;
					}
					if ($ops % 10000 == 0) {
						msg(undef, sprintf("%1d:%5d ", $nbits, int($ops/1000)));
					}
					my $thisbits = $block;
					for (my $j = 0; $j < $nbits; $j++) {
						vec($thisbits, $i + $j, 1) ^= (vec $dbits, $j, 1);
					}
					my $thischeck = chk($thisbits);  
					if (bitdist($thischeck, $checksum) <= $limit_checksum_dist) {
						push @hits, [$thisbits, $thischeck];
						$found = 1;
					}
				}
			}
		}
		if ($found or $stop) {
			last;
		}
	}

	my $nhits = scalar @hits;
	if (!$nhits) {
		my $thisblockbytesize = length $block;
		print $rh pack("a8 Q Q Q Q", 'NOHITS', $theblock, $thisblockbytesize, 0, 0);
		print $rh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $checksum, $block);
		printf $rht "block %20d \@%9d operations: NOHITS\n", $theblock, $ops;
		msg(0, sprintf("Could not repair block %20d", $theblock));
		return 0;
	}
	if ($nhits > 1) {
		my ($mindistance, $minblock, $mincheck);

		my $totaldistance = 0;
		for my $hit (@hits) {
			my ($thisblock, $thischecksum) = @$hit;
			my $dist = dst($checksum, $thischecksum, $block, $thisblock);
			$totaldistance += $dist;
			if (!defined($mindistance) or $dist < $mindistance) {
				$mindistance = $dist;
				$minblock = $thisblock;
				$mincheck = $thischecksum;
			}
			my $thisblockbytesize = length $thisblock;
			print $rh pack("a8 Q Q Q Q", 'HIT', $theblock, $thisblockbytesize, $dist, 0);
			print $rh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $thischecksum, $thisblock);
			printf $rht "block %20d \@%9d operations: HIT  at distance %d\n", $theblock, $ops, $dist;
		}
		my $ambival = ambival($nhits, $mindistance, $totaldistance / $nhits);
		my $minblockbytesize = length $minblock;
		print $rh pack("a8 Q Q Q Q", 'HIT?', $theblock, $minblockbytesize, $mindistance, $ambival);
		print $rh pack(sprintf("a%d a%d", $checksumbytesize, $minblockbytesize), $mincheck, $minblock);
		printf $rht "block %20d \@%9d operations: HIT? at distance %d with ambival %d\n", $theblock, $ops, $mindistance, $ambival;
		return -$ambival;
	}
#	now $nhits == 1
	my ($thisblock, $thischecksum) = @{$hits[0]};
	my $dist = dst($block, $thisblock, $checksum, $thischecksum);
	my $thisblockbytesize = length $thisblock;
	print $rh pack("a8 Q Q Q Q", 'HIT!', $theblock, $thisblockbytesize, $dist, 0);
	print $rh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $thischecksum, $thisblock);
	printf $rht "block %20d \@%9d operations: HIT! at distance %d\n", $theblock, $ops, $dist;
	return 1;
}

=head2 RESTORE BLOCK

This function implements a main step: Restore a single block

=cut

sub restoreblock {
	my ($theblock, $block, $blockbu, $checksum, $checksumbu) = @_;

	my $nblockbytes = length $block;
	my $nblockbubytes = length $blockbu;
	if ($nblockbytes ne $nblockbubytes) {
		msg(-2, sprintf("Backup block and data block have different lengths: %d versus %d", $nblockbubytes, $nblockbytes));
		my $thisblockbytesize = length $block;
		print $rbh pack("a8 Q Q Q Q", 'BLENGTH?', $theblock, $thisblockbytesize, 0, 0);
		print $rbh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $checksum, $block);
		printf $rbht "block %20d: BLENGTH? data=%d,  backup=%d\n", $theblock, $nblockbytes, $nblockbubytes;
		return 0;
	}
	my $nchecksumbytes = length $checksum;
	my $nchecksumbubytes = length $checksumbu;
	if ($nchecksumbytes ne $nchecksumbubytes) {
		msg(-2, sprintf("Backup checksum and data checksum have different lengths: %d versus %d", $nchecksumbubytes, $nchecksumbytes));
		my $thisblockbytesize = length $block;
		print $rbh pack("a8 Q Q Q Q", 'CLENGTH?', $theblock, $thisblockbytesize, 0, 0);
		print $rbh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $checksum, $block);
		printf $rbht "block %20d: CLENGTH? data=%d,  backup=%d\n", $theblock, $nchecksumbytes, $nchecksumbubytes;
		return 0;
	}

	my $diffmask = $block ^ $blockbu;

# get the indices of the 1 bits
	my @hits = ();
	my @diffbits = ();
	for (my $i = 0; $i < length($diffmask) * 8; $i++) {
		my $bit = vec $diffmask, $i, 1;
		if ($bit) {
			push @diffbits, $i;
		}
	}
	my $ndiffbits = scalar @diffbits;

	my $ops = 0;
	for (1) {
		if (!$ndiffbits) {
			my $thischeck = chk($block);  
			if (bitdist($thischeck, $checksum) < $limit_checksum_dist or bitdist($thischeck, $checksumbu) < $limit_checksum_dist) {
				push @hits, [$block, $thischeck];
			}
			next;
		}
		if ($ndiffbits > $mask_size_block) {
			if (chk($blockbu) eq $checksum) {
				msg(0, "Current checksum matches backup block =ok=> will restore from backup"); 
				push @hits, [$blockbu, $checksum];
				next;
			}
			else {
				msg(-1, sprintf("Data and backup differ in too many bits: (%d)", $ndiffbits));
				msg(0, "Current checksum does not match backup block =xx=> limited restore from backup"); 
			}
		}

# now generate the set by creating all possible bit values at the positions where $str1 and $str2 differ 
# in order to optimize the search process, we want to search in such a way that we do cases first where bits are taken
# consecutively from the data version or the backup version.
# The reason is that errors come in bursts. Hence, if backup and data differ in bit i and bit i+1, both bits are likely to be correct in either backup
# or in data. It is much less likely that bit i is correct in data and bit i+1 in backup, or vice versa.
# So if the max number of brute force operations does not permit full traversal, we do a partial traversal with the most likely suspects first.
# This will increase the change of finding a good restore.

# So we generate all possibile bit strings for the difference mask. We will xor the bits in the mask with the corresponding bits in the data.
# So we should try bitstrings first with minimal alterations between 1s and 0s.

		my $stop = 0;
		
		for (my $ns = 0; $ns < $ndiffbits; $ns++) {

# Here we are in the situation that we have to generate all bitstring with exactly $ns swap positions
# we keep the swap positions in an array @swappos
# that means: $swappos[0] is the first position where a bit swap must occur, it is a value between 0 and $ndiffbits - 1
# we make two arrays with the lower and upper bounds for the swap positions @swappos_lower, @swappos_upper

			my @swappos_upper = ();
			for (my $sp = 0; $sp < $ns; $sp++) {
				$swappos_upper[$sp] = $ndiffbits - 1 - ($ns - $sp);
			}

# we initialize @swappos

			my @swappos = ();
			for (my $sp = 0; $sp < $ns; $sp++) {
				$swappos[$sp] = $sp;
			}

# now iterate over all possible values of @swappos below (including) the boundaries @swappos_upper
# we use a simple while loop
# the trick is to find the next @swappos value efficiently and to flag a stop condition if there is not any
# But first we have to generate the bitstring and do the work for the current value of @swappos

			my $isgoing = 1;
			while ($isgoing) {
				$ops += 2;
				if ($ops > $bruteforce) {
					$stop = 1;
					last;
				}
				if ($ops % 10000 == 0) {
					msg(undef, sprintf("%7d", int($ops/1000)));
					msg(undef, sprintf("%1d:%5d ", $ns, int($ops/1000)));
				}

# translate the swappos positions into an index in the diffmask that for each position tells whether a swap will follow
# record which counters are still incrementable
				my $last_sp_not_full;
				my @swapposindex = ();
				for (my $sp = 0; $sp < $ns; $sp++) {
					$swapposindex[$swappos[$sp]] = 1;
					my $thisfull = $swappos[$sp] == $swappos_upper[$sp];
					if (!$thisfull) {
						$last_sp_not_full = $sp;
					}
				}
				my $thisbits1 = $block;
				my $thisbits2 = $block;
				my $bit1 = 0;
				my $bit2 = 1;
				for (my $i = 0; $i < $ndiffbits; $i++) {
# set the bits in the block accordingly
					vec($thisbits1, $diffbits[$i], 1) ^= $bit1;
					vec($thisbits2, $diffbits[$i], 1) ^= $bit2;
# honour the bit swaps
					if ($swapposindex[$i]) {
						$bit1 = 1 - $bit1;
						$bit2 = 1 - $bit2;
					}
				}

				my $thischeck1 = chk($thisbits1);  
				my $thischeck2 = chk($thisbits2);  
				if (bitdist($thischeck1, $checksum) < $limit_checksum_dist or bitdist($thischeck1, $checksumbu) < $limit_checksum_dist) {
					push @hits, [$thisbits1, $thischeck1];
				}
				if (bitdist($thischeck2, $checksum) < $limit_checksum_dist or bitdist($thischeck2, $checksumbu) < $limit_checksum_dist) {
					push @hits, [$thisbits2, $thischeck2];
				}

# now find next and determine whether to stop

				if (!defined $last_sp_not_full) {
					$isgoing = 0;
					last;
				}
				my $initpos = ++$swappos[$last_sp_not_full];
				for (my $sp = $last_sp_not_full + 1; $sp < $ns; $sp++) {
					$swappos[$sp] =  ++$initpos;
				}
			}
			if ($stop) {
				last;
			}
		}
	}

	my $nhits = scalar @hits;
	if (!$nhits) {
		my $thisblockbytesize = length $block;
		print $rbh pack("a8 Q Q Q Q", 'NOHITS', $theblock, $thisblockbytesize, 0, 0);
		print $rbh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $checksum, $block);
		printf $rbht "block %20d \@%9d: NOHITS\n", $theblock, $ops;
		return 0;
	}
	if ($nhits > 1) {
		my ($mindistance, $minblock, $mincheck);

		my $totaldistance = 0;
		for my $hit (@hits) {
			my ($thisblock, $thischecksum) = @$hit;
			my $dist = dst($block, $thisblock, $checksum, $thischecksum);
			$totaldistance += $dist;
			if (!defined($mindistance) or $dist < $mindistance) {
				$mindistance = $dist;
				$minblock = $thisblock;
				$mincheck = $thischecksum;
			}
			my $thisblockbytesize = length $thisblock;
			print $rbh pack("a8 Q Q Q Q", 'HIT', $theblock, $thisblockbytesize, $dist, 0);
			print $rbh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $thischecksum, $thisblock);
			printf $rbht "block %20d \@%9d: HIT at distance %d\n", $theblock, $ops, $dist;
		}
		my $ambival = ambival($nhits, $mindistance, $totaldistance / $nhits);
		my $minblockbytesize = length $minblock;
		print $rbh pack("a8 Q Q Q Q", 'HIT?', $theblock, $minblockbytesize, $mindistance, $ambival);
		print $rbh pack(sprintf("a%d a%d", $checksumbytesize, $minblockbytesize), $mincheck, $minblock);
		printf $rbht "block %20d \@%9d: HIT? at distance %d with ambival %d\n", $theblock, $ops, $mindistance, $ambival;
		return -$ambival;
	}
#	now $nhits == 1
	my ($thisblock, $thischecksum) = @{$hits[0]};
	my $dist = dst($block, $thisblock, $checksum, $thischecksum);
	my $thisblockbytesize = length $thisblock;
	print $rbh pack("a8 Q Q Q Q", 'HIT!', $theblock, $thisblockbytesize, $dist, 0);
	print $rbh pack(sprintf("a%d a%d", $checksumbytesize, $thisblockbytesize), $thischecksum, $thisblock);
	printf $rbht "block %20d \@%9d: HIT! at distance %d\n", $theblock, $ops, $dist;
	return 1;
}

*dst = *dst_classic;

sub dst_classic {
	my ($checksum1, $checksum2, $block1, $block2) = @_;
	my $cdiff = bitdist($checksum1, $checksum2);
	my $bdiff = bitdist($block1, $block2);
	my $dist = $bdiff + $check_diff_penalty * $redundancy * $cdiff;
	return $dist;
}

sub dst_square {
	my ($checksum1, $checksum2, $block1, $block2) = @_;
	my $cdiff = bitdist($checksum1, $checksum2);
	my $bdiff = bitdist($block1, $block2);
	my $dist = $bdiff * $bdiff + $check_diff_penalty * $redundancy * $cdiff * $cdiff;
	return $dist;
}

sub dst_conservative {
	my ($checksum1, $checksum2, $block1, $block2) = @_;
	my $cdiff = bitdist($checksum1, $checksum2);
	my $bdiff = bitdist($block1, $block2);
	my $dist = $bdiff * $cdiff * ($bdiff + $check_diff_penalty * $redundancy) * $cdiff;
	return $dist;
}

sub dst_conservative_biased {
	my ($checksum1, $checksum2, $block1, $block2) = @_;
	my $cdiff = bitdist($checksum1, $checksum2);
	my $bdiff = bitdist($block1, $block2);
	my $dist = $bdiff * $cdiff * ($bdiff + $check_diff_penalty * $redundancy) * $cdiff + $cdiff;
	return $dist;
}

sub ambival {
	my ($nhits, $mindistance, $avdistance) = @_;
	my $clarity = $avdistance - $mindistance;
	return int(100 * ($clarity ? ($nhits * $mindistance) / $clarity : $nhits * $mindistance * 10_000)); 
}

=head2 dithering

This is the technique used for repairing blocks.

Dithering is subtly mangling a bit string, by introducing a limitied amount of bit errors.
We let an imaginary frame of fixed width slide over the bitstring, and inside the frame
we generate all possible bit errors.

More precisely, n-dithering is dithering with a frame of exactly width n.
And <=n-dithering is dithering with frames of width 1 to n.

If we do n-dithering, we generate bitstrings of length n, and x-or the input bitstring with it,
at a reference position that slides throughout the input.

Bit 0 and bit n-1 of an n-frame are always 1. If one or of them would be 0, we would have an n-1 frame,
or an n-2 frame, or even less. We would be doing double work then.

Bits 1 up to and including n-2 range over the full set of possible bitstrings of length n-2.

n-ditherings and m ditherings are mutually exclusive when n <> m.
This is precisely because the end points are always one, and the endpoints change the input bitstring.

So the number of ditherings with frame length <= n is:  2 ^ (n-1) 

=cut

# generate all dither frames of length n

sub gen_dither_frames {
	my $nbits = shift;
	if ($nbits == 0) {
		return ();
	}
	if ($nbits == 1) {
		my $bits = '';
		vec($bits, 0, 1) = 1;
		return ($bits);
	}
	if ($nbits == 2) {
		my $bits = '';
		vec($bits, 0, 1) = 1;
		vec($bits, $nbits - 1, 1) = 1;
		return ($bits);
	}
	my @result = ();
	for (my $i = 0; $i < 1 << $nbits - 2; $i++) {
		my $format = sprintf '%%0%db', $nbits - 2;
		my $bitstring = sprintf $format, $i;
		my $bits = '';
		vec($bits, 0, 1) = 1;
		vec($bits, $nbits - 1, 1) = 1;
		my $pos = 1;
		for my $bit (split //, $bitstring) {
			vec($bits, $pos++, 1) = $bit;
		}
		push @result, $bits;
	}
	return @result;
}

=head2 Masking

This is the technique used for restoring blocks.
When the corresponding block from the backup is fetched, and we have the data block,
then in the most general case we do not know which block is right.
They could be both wrong. Even the checksums could be all wrong.

We assume however, that the bits in which they agree are correct.

So me make a mask of the differing bits, and we create all bit variations in that mask.

We try them all out by brute force.

So there is good chance that we find a hit, even if all initial data is corrupted.

=cut

=head2 Distances

In the rare case that there are multiple hits, we choose the hit with least distance to our
initial data.

bitdist(str1, str2) computes the distance between two bitstrings.

=cut

sub bitdist {
	my ($str1, $str2) = @_;
	my $diffmask = $str1 ^ $str2;
	return unpack("%256b*", $str1 ^ $str2);
}


=head2 Pretty printing a block of bits

=cut

sub pretty {
	my $bitstring = shift;
	my @bytes = map {scalar(reverse(sprintf("%08b", ord($_))))} split(//, $bitstring);
	my $result = sprintf "%d bytes = %d bits:\n", length($bitstring), length($bitstring) * 8;
	my $nbytes = 0;
	my $bytesperline = 16;
	while (scalar(@bytes)) {
		$result .= shift @bytes;
		$result .= ' ';
		$nbytes++;
		if ($nbytes == $bytesperline) {
			$result .= "\n";
			$nbytes = 0;
		}
	}
	$result .= "\n";
	return $result;	 
}

# generates a sequence of 0 and 1s indicate where its two argument differ, as a bit string. Where ever there is a 1, they differ.

sub diffbitstring {
	my ($str1, $str2) = @_;
	return join(' ', map {scalar(reverse(sprintf("%08b", ord($_))))} split(//, unpack('a*', $str1 ^ $str2)));
}

sub resolve {
	my ($val1, $val2) = @_;
	if (ispower2($val1) and ispower2($val2)) {
		if ($val1 == $val2) {
			return $val1;
		}
		else {
			return undef;
		}
	}
	if (ispower2($val1) and !ispower2($val2)) {
		return $val1;
	}
	if (ispower2($val2) and !ispower2($val1)) {
		return $val2;
	}
	return undef;
}

sub ispower2 {
	my $val = shift;
	if (!$val) {
		return 0;
	}
	if ($val == 1) {
		return 1;
	}
	if ($val % 2) {
		return 0;
	}
	return ispower2($val / 2);
}

sub dummy { # only for debugging
	1;
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
		if ($kind > 0) {
			print STDOUT $text;
		}
		if (!defined $lh or $kind < 0 or ($kind == 0 and $verbose)) {
			print STDERR $text;
		}
		if (defined $lh) {
			print $lh $text;
		}
	}
}

=head2 MAIN

chain the steps together and deliver results
However, the program just executes one main step.
The user is responsible to take decisions on the basis
of previous steps.

=cut

sub main {
	my $good = 1;
	if (!init()) {
		$good = 0;
	}
	for my $task (@taskorder) {
		if (!$task{$task}->{do}) {
			next;
		}
		if ($good) {
			msg(0, sprintf("Doing [%s]", $task));
			my $thetask = "task_$task";
			if (!&$thetask()) {
				$good = 0;
			}
		}
		else {
			msg(0, sprintf("Skipping [%s]", $task));
		}
	}
	close $lh;
	return $good;
}

exit !main();
