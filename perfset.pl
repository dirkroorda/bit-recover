#!/usr/bin/perl
use bytes;
use strict;
use warnings;
no warnings "uninitialized";
no strict "refs";

use FileHandle;
use Getopt::Long qw(:config no_ignore_case);
use Time::HiRes qw (gettimeofday time tv_interval);

=head1 DESCRIPTION

Generates a test sets from a base file called dataname-orig in a root directory.
The root directory and some other parameters are defined by the experiment.
There are several experiments spelled out below, the first argument selects a specific one.
An original data file is corrupted and copied to form the starting point of several parts of the test set.
Each part correspondes to a checksum method such as md5 or sha256.
Corruption is pseudo random, no two corruptions will be the same.
From then on both parts will be subjected to checksum tests and error correcting.

=cut

# BEGIN configuration section

# methods

my @methodorder = qw(
	md5_16
	md5_32
	md5_64
	crc32
	md4
	md5
	sha256
);

my $checksumscript = 'checksum.pl';
my $corruptscript = 'corrupt.pl';

# experiments

my %experiment = (
	'0-xxsmall' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 200,
			restore => 200,
		},
	},
	'1-xsmall' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 1_000,
			restore => 1_000,
		},
	},
	'2-small' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 5_000,
			restore => 5_000,
		},
	},
	'3-medium' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 25_000,
			restore => 25_000,
		},
	},
	'4-large' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 125_000,
			restore => 125_000,
		},
	},
	'5-xlarge' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 625_000,
			restore => 625_000,
		},
	},
	'6-xxlarge' => {
		pool => 'experiment',
		methods => '
			             32:crc32,  32:md5_32,  32:md5_64,  32:md5,  32:sha256,
			 64:md5_16,  64:crc32,  64:md5_32,  64:md5_64,  64:md5,  64:sha256,
			128:md5_16, 128:crc32, 128:md5_32, 128:md5_64, 128:md5            
			',
		bruteforce => {
			repair => 3_125_000,
			restore => 3_125_000,
		},
	},

	repairhugesparse => {
		pool => 'hugesparse',
		methods => '256:md5_64, 128:md5, 64:sha256',
		bruteforce => {
			repair => 1_000_000,
			restore => 1_000_000,
		},
	},

	restorehugesparse => {
		pool => 'hugesparse',
		methods => '256:md5_64, 128:md5, 64:sha256',
		bruteforce => {
			repair => 1000,
			restore => 10_000_000,
		},
	},
	test1 => {
		pool => 'test',
		methods => '32:md5_16, 32:md5, 32:sha256',
		bruteforce => {
			repair => 10_000,
			restore => 10_000,
		},
	},
	test2 => {
		pool => 'test',
		methods => '128:md5_64',
		bruteforce => {
			repair => 10_000,
			restore => 100_000,
		},
	},
);

# pool of prepared data for experiments

my %pool = (
	experiment => {
		rootdir => '../experiment/',
		datafiles => 'zutphen.jpg',
		corruption => {
			data => {
				burstlength => 20,
				number => 200,
			},
			backup => {
				burstlength => 19,
				number => 190,
			},
			datachk => {
				burstlength => 5,
				number => 60,
			},
			backupchk => {
				burstlength => 4,
				number => 50,
			},
		},
	},
	hugesparse => {
		rootdir => '~/Scratch/bitpreserve',
		datafiles => 'testhuge.dmg',
		corruption => {
			data => {
				burstlength => 10,
				number => 1_000,
			},
			backup => {
				burstlength => 5,
				number => 500,
			},
			datachk => {
				burstlength => 3,
				number => 20,
			},
			backupchk => {
				burstlength => 2,
				number => 20,
			},
		},
	},
	hugedense => {
		rootdir => '~/Scratch/bitpreserve',
		datafiles => 'testhuge.dmg',
		corruption => {
			data => {
				burstlength => 20,
				number => 10_000,
			},
			backup => {
				burstlength => 10,
				number => 5_000,
			},
			datachk => {
				burstlength => 6,
				number => 400,
			},
			backupchk => {
				burstlength => 4,
				number => 200,
			},
		},
	},
	test => {
		rootdir => '~/Scratch/bitpreserve',
		datafiles => 'dirk.jpg',
		corruption => {
			data => {
				burstlength => 10,
				number => 100,
			},
			backup => {
				burstlength => 20,
				number => 400,
			},
			datachk => {
				burstlength => 4,
				number => 10,
			},
			backupchk => {
				burstlength => 3,
				number => 9,
			},
		},
	},
);

# logging and reporting

my @kindrep = (
	'Error',
	'Warning',
	'Info',
	undef,
);

my $opt_verbose = 0;
my $opt_debug = 0;
my $opt_fresh = 0;
my $opt_compare = 0;

# END configuration section

my $experiment;
my $scenario;
my $timestamp;
my @activeexperiments = ();
my @activemethods = ();
my %method = ();
my %datafile = ();
my %pathdefs = ();
my %path = ();
my %time = ();
my ($thedatafile, $themethod, $theredundancy);
my @checksumcmd;
my @corruptcmd;
my $subgood;
my $checkarg;
my $lh;

=head2 Command line

	./perfset.sh [-v] [-v] [-d] -e experiment [-tm timestamp]

where 
	-v				verbose rsync, if twice: verbose all
	-d				debug mode when calling perl scripts
	-f				force fresh corruption
	-c				execute the changes and perform final check
	-e experiment	key of %experiment

=cut

sub getcommandline {
	$checkarg = 1;

	if (!GetOptions(
		'verbose|v+' => \$opt_verbose,
		'debug|d!' => \$opt_debug,
		'fresh|f!' => \$opt_fresh,
		'compare|c!' => \$opt_compare,
		'experiment|e=s@{,}' => \&checkarg,
		'timestamp|tm=s' => \$timestamp,
	)) {
		$checkarg = 0;
	}
	if (defined $timestamp) {
		if ($timestamp !~ m/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}$/) {
			msg(-2, sprinftf("Timestamp expected instead of [%s]", $timestamp));
			$checkarg = 0;
		}
	}
	if (!scalar @activeexperiments) {
		msg(-2, sprintf("No experiment chosen. Choose one of [%s]", join(',', sort(keys(%experiment)))));
		$checkarg = 0;
	}

	return $checkarg;
}

sub checkarg {
	my ($name, $value, $hashvalue) = @_;
	for (1) {
		if ($name eq 'experiment') {
			if (!exists $experiment{$value}) {
				msg(-2, sprintf("Unknown experiment [%s]. Allowed experiments are [%s]", $value, join(",", sort(keys(%experiment)))));
			}
			else {
				push @activeexperiments, $value;
			}
			next;
		}
	}
}

sub setexperiment {
	my $experimentinfo = $experiment{$experiment};
	my $poolname = $experimentinfo->{pool};
	my $poolinfo = $pool{$poolname};
	%datafile = ();
	@activemethods = ();
	if (!defined $poolinfo) {
		msg(-2, sprintf("Unknown pool [%s] specified in experiment [%s]. Allowed pools are [%s]", $poolname, $experiment, join(",", sort(keys(%pool)))));
		return 0;
	}
	$scenario = $experimentinfo;
	for my $key (keys %$poolinfo) {
		$scenario->{$key} = $poolinfo->{$key};
	}
	my $rootdir = $scenario->{rootdir};
	my $good = 1;
	if (!scalar(keys(%datafile))) {
		my $datafiles = $scenario->{datafiles};
		if (defined $datafiles) {
			for my $df (split /\s*,\s*/, $datafiles) {
				if (!adddatafile($df)) {
					$good = 0;
				}
			}
		}
	}
	my $methods = $scenario->{methods};
	if (defined $methods) {
		$methods =~ s/^\s+//s;
		$methods =~ s/\s+$//s;
		for my $m (split /\s*,\s*/s, $methods) {
			if (!addmethod($m)) {
				$good = 0;
			}
		}
	}
	if (!scalar(@activemethods)) {
		msg(-2, sprintf("No methods selected. Choose at least one of [%s] in experiment [%s]", join(',',@methodorder), $experiment));
		$good = 0;
	}

	my $pooldir	= "$rootdir/pool";
		my $origdir = "$pooldir/orig";
		my $corruptdir = "$pooldir/corrupt";

	my $repdir	= "$rootdir/report";
	my $tempdir	= "$rootdir/temp";

	%pathdefs = (
		origdir				=> $origdir,
		origfile			=> $origdir.'/S{datafile}',
		origmethod			=> $origdir.'/S{redundancy}-S{method}',
		origchkfile			=> $origdir.'/S{redundancy}-S{method}/S{datafile}.chk',
		origchklogfile		=> $origdir.'/S{redundancy}-S{method}/S{datafile}.log',
		corruptdir			=> $corruptdir,
		corruptmethod		=> $corruptdir.'/S{redundancy}-S{method}',
		datafile			=> $corruptdir.'/S{datafile}-S{cd}',
		datachkfile			=> $corruptdir.'/S{redundancy}-S{method}/S{datafile}-S{ccd}.chk',
		datachklogfile		=> $corruptdir.'/S{redundancy}-S{method}/S{datafile}-S{ccd}.log',
		backupfile			=> $corruptdir.'/S{datafile}-S{cb}.bu',
		backupchkfile		=> $corruptdir.'/S{redundancy}-S{method}/S{datafile}-S{ccb}.bu.chk',
		dataxfile			=> $corruptdir.'/S{redundancy}-S{method}/S{datafile}-S{cd}-S{ccd}.x',
		dataxtxtfile		=> $corruptdir.'/S{redundancy}-S{method}/S{datafile}-S{cd}-S{ccd}.x.txt',
		repdir				=> $repdir,
		expdirbase			=> $repdir.'/S{experiment}',
		expdir				=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}',
		explog				=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}/S{redundancy}-S{method}.exp.txt',
		repairfile			=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}/S{redundancy}-S{method}.ri',
		repairtxtfile		=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}/S{redundancy}-S{method}.ri.txt',
		restorefile			=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}/S{redundancy}-S{method}.rib',
		restoretxtfile		=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}/S{redundancy}-S{method}.rib.txt',
		diagfile			=> $repdir.'/S{experiment}/S{bfrepair}-S{bfrestore}/S{timestamp}/S{datafile}/S{cd}-S{ccd}-S{cb}-S{ccb}/S{redundancy}-S{method}.diag.txt',
		tempdir				=> $tempdir,
		renewfile			=> $tempdir.'/S{datafile}-S{bfrepair}-S{bfrestore}-S{cd}-S{ccd}-S{cb}-S{ccb}=S{redundancy}-S{method}',
	);

	return $good;
}

# files involved in the test

sub init {
	for my $item (@methodorder) {
		$method{$item} = 1;
	}
	if (!getcommandline()) {
		return 0;
	}
	@checksumcmd = ('perl');
	@corruptcmd = ('perl');
	push @checksumcmd, $checksumscript;
	push @corruptcmd, $corruptscript;
	if ($opt_verbose > 1) {
		push @checksumcmd, '-s';
		push @corruptcmd, '-s';
	}
	return 1;
}

sub pool {
	my $good = 1;
	my $corruption = $scenario->{corruption};

	timestamp('pool');
	msg(1, sprintf("%s %-21s = %s checking pool %s", elapsed('pool'), 'POOL', $scenario->{pool}));
	for my $datafile (sort keys %datafile) {
		my $refreshed = 0;
		if (!adjustpaths($datafile)) {
			$good = 0;
			next;
		}
		if (! -f $path{origfile}) {
			msg(-2, sprintf("Original file not found: [%s]", $path{origfile}));
			$good = 0;
			next;
		}	
		if (!makedir($path{corruptdir})) {
			$good = 0;
			next;
		}
		my $thisgood = 1;
		for my $item (
			[$path{origfile}, $path{datafile}, $corruption->{data}->{burstlength}, $corruption->{data}->{number}],
			[$path{origfile}, $path{backupfile}, $corruption->{backup}->{burstlength}, $corruption->{backup}->{number}],
		) {
			my ($src, $dst, $cb, $cn) = @$item;
			if ($opt_fresh or ! -f $dst) {
				if (!copyfile($src, $dst)) {
					$good = 0;
					next;
				}
				if (!executecmd(@corruptcmd, '-b', $cb, '-n', $cn, '--data', $dst)) {
					$good = 0;
					next;
				}
				$refreshed = 1;
			}	
		}
		if (!$thisgood) {
			$good = 0;
			next;
		}

		for my $methodspec (@activemethods) {
			if (!adjustpaths($datafile, $methodspec)) {
				$good = 0;
				next;
			}
			if (!makedir($path{origmethod})) {
				$good = 0;
				next;
			}
			if (!makedir($path{corruptmethod})) {
				$good = 0;
				next;
			}
			if (! -f $path{origchkfile}) {
				if (!executecmd(@checksumcmd,
						'--task',
							'generate',
						'--redundancy',
							$theredundancy,
						'--method',
							$themethod,
						'--data',
							"data=$path{origfile}",
						'--conf',
							"log=$path{origchklogfile}",
							"checksum=$path{origchkfile}",
				)) {
					$good = 0;
					next;
				}
				$refreshed = 1;
			}
			for my $item (
				[$path{origchkfile}, $path{datachkfile}, $corruption->{datachk}->{burstlength}, $corruption->{datachk}->{number}],
				[$path{origchkfile}, $path{backupchkfile}, $corruption->{backupchk}->{burstlength}, $corruption->{backupchk}->{number}],
			) {
				my ($src, $dst, $cb, $cn) = @$item;
				if ($refreshed or $opt_fresh or ! -f $dst) {
					if (!copyfile($src, $dst)) {
						$good = 0;
						next;
					}
					if (!executecmd(@corruptcmd, '-b', $cb, '-n', $cn, '--data', $dst)) {
						$good = 0;
						next;
					}
					$refreshed = 1;
				}	
			}
			if ($refreshed or $opt_fresh or ! -f $path{dataxfile}) {
				if (!executecmd(@checksumcmd,
						'--task',
							'verify',
						'--data',
							"data=$path{datafile}",
						'--conf',
							"log=$path{datachklogfile}",
							"checksum=$path{datachkfile}",
							"error=$path{dataxfile}",
							"errortxt=$path{dataxtxtfile}",
				)) {
					$good = 0;
					next;
				}
				$refreshed = 1;
			}
		}
	}
	timestamp('experiment');
	msg(1, sprintf("%s %-21s = %s pool done %s", elapsed('pool'), 'POOL', $scenario->{pool}));
	return $good;
}

sub do_experiment {
	if (!pool()) {
		return 0;
	}
	my $good = 1;
	for my $datafile (sort keys %datafile) {
		for my $methodspec (@activemethods) {
			if (!adjustpaths($datafile, $methodspec)) {
				$good = 0;
				next;
			}
			if (!makedir($path{expdir})) {
				$good = 0;
				next;
			}
			$lh = openwrite($path{explog});
			if (!defined $lh) {
				$good = 0;
				next;
			}
			for (1) {
				if (!executecmd(@checksumcmd,
						'--task',
							'repair',
							'restore',
							'diag',
						'--bruteforce',
							"repair=$scenario->{bruteforce}->{repair}",
							"restore=$scenario->{bruteforce}->{restore}",
						'--data',
							"data=$path{datafile}",
							"backup=$path{backupfile}",
							"orig=$path{origfile}",
							"corrupt=$path{datafile}",
						'--conf',
							"log=$path{datachklogfile}",
							"diag=$path{diagfile}",
							"error=$path{dataxfile}",
							"repair=$path{repairfile}",
							"repairtxt=$path{repairtxtfile}",
							"restore=$path{restorefile}",
							"restoretxt=$path{restoretxtfile}",
							"checksumbu=$path{backupchkfile}",
				)) {
					$good = 0;
					next;
				}
				if ($opt_compare) {
					if (!makedir($path{tempdir})) {
						return 0;
					}
					if (!copyfile($path{datafile}, $path{renewfile})) {
						$good = 0;
						next;
					}
					if (!executecmd(@checksumcmd,
							'--task',
								'execute_repair',
								'execute_restore',
							'--data',
								"data=$path{renewfile}",
							'--conf',
								"log=$path{datachklogfile}",
								"repair=$path{repairfile}",
								"restore=$path{restorefile}",
					)) {
						$good = 0;
					}
					if (!executecmd('diff', '-s', $path{origfile}, $path{renewfile})) {
						$good = 0;
					}
					unlink $path{renewfile};
				}
			}
			closefile($$lh);
		}
	}
	return $good;
}

sub actions {
	my $good = 1;
	for my $exp (@activeexperiments) {
		$experiment = $exp;
		timestamp('experiment');
		msg(1, sprintf("%s %-21s = %s starting", elapsed('program'), 'EXPERIMENT', $experiment));
		my $thisgood = 1;
		if (!setexperiment()) {
			$thisgood = 0;
			next;
		}
		if ($thisgood) {
			msg(0, sprintf("Doing experiment [%s]", $exp));
			if (!do_experiment()) {
				$thisgood = 0;
			}
		}
		else {
			msg(0, sprintf("Skipping experiment [%s]", $exp));
		}
		msg(1, sprintf("%s %-21s = %s finished with GOOD=%d", elapsed('experiment'), 'EXPERIMENT', $experiment, $thisgood));
		if (!$thisgood) {
			$good = 0;
		}
	}
	return $good;
}

sub executecmd {
	my @cmd = @_;
	my $cmdstr = '';
	my $cmdstrrep = '';
	my $good = 1;
	my $sep = '';
	my $interactive = 0;

	for my $word (@cmd) {
		$cmdstrrep .= $sep.fname($word);
		if ($word =~ m/ /) {
			$cmdstr .= "$sep'$word'";
		}
		else {
			$cmdstr .= "$sep$word";
		}
		if ($sep eq '' and $opt_debug and $word eq 'perl') {
			$interactive = 1;
			$cmdstr .= ' -d';
		}
		$sep = ' ';
	}
	if (length($cmdstrrep) > 80) {
		$cmdstrrep = substr($cmdstrrep, 0, 40). '...' . substr($cmdstrrep, -40);
	}

	my $text;
	my $msgrep = 'success';
	timestamp('cmd');
	$text = sprintf "%s %-21s - executing [%s]", elapsed('cmd'), 'EXEC', $cmdstrrep;
	msg(1, $text);

	if (!$interactive) {
		if (!open(CMD, "$cmdstr |")) {
			$good = 0;
		}
		else {
			while (my $line = <CMD>) {
				chomp $line;
				$text = sprintf "%s %s", elapsed('cmd'), $line;
				msg(1, trim($text));
			}
			if (!close CMD) {
				$good = 0;
				$msgrep = 'failed';
			}
		}
	}
	else {
		my $thisgood = system $cmdstr;
		if (!$thisgood) {
			$good = 0;
			$msgrep = 'failed';
		}
	}
	$text = sprintf "%s %-21s - %s [%s]", elapsed('cmd'), 'EXEC', $msgrep, $cmdstrrep;
	msg(1, $text);

	return $good;
}

sub copyfile {
	my ($src, $dst, $move) = @_;
	my $srcrep = fname($src);
	my $dstrep = fname($dst);
	my $label = $move ? 'MOVE' : 'COPY';
	my $rsyncbase = 'rsync --out-format="" --progress';
	if (!$opt_verbose) {
		$rsyncbase .= ' -q';
	}
	my $cmd;
	if ($move) {
		$cmd = $rsyncbase . ' --remove-source-files';
	}
	else {
		$cmd = $rsyncbase;
	}
	#my $cmd = $move ? 'mv' : 'cp';
	my $action = $move ? 'moving' : 'copying';
	my $done = $move ? 'moved' : 'copied';

	timestamp(lc($label));
	my $good = 1;
	my $text;
	$text = sprintf "%s %-21s - %s [%s] to [%s]", elapsed(lc($label)), $label, $action, $srcrep, $dstrep;
	msg(1, $text);

	my $msgrep = $done;
	if (system "$cmd '$src' '$dst'") {
		$good = 0;
		$msgrep = sprintf "failed to %s", lc($label);
	}
	else {
		print STDERR "\r";
	}
	$text = sprintf "%s %-21s - %s  [%s] to [%s]", elapsed(lc($label)), $label, $msgrep, $srcrep, $dstrep;
	msg(1, $text);

	return $good;
}

sub adddatafile {
	my ($arg) = @_;
	my $good = 1;
	if (exists $datafile{$arg}) {
		msg(-2, sprintf("Basename [%s] repeated on command line or in experiment", $arg));
	}
	else {
		$datafile{$arg} = 1;
	}
	return $good;
}

sub addmethod {
	my $methodspec = shift;
	my ($redundancy, $method) = $methodspec =~ m/^([0-9]+):(.+)$/;
	if (!defined $method) {
		msg(-2, sprintf("Not a valid combination of redundancy and checksum method [%s]", $methodspec));
		return 0;
	}
	my $info = $method{$method};
	if (!defined $info) {
		msg(-2, sprintf("No such method [%s]. Choose one of [%s]", $method, join(',',sort(keys(%method)))));
		return 0;
	}
	else {
		push @activemethods, [$redundancy, $method];
	}
	return 1;
}

sub adjustpaths {
	my ($datafile, $methodspec) = @_;
	my $good = 1;
	my ($redundancy, $method) = @$methodspec;
	$thedatafile = $datafile;
	$theredundancy = $redundancy;
	$themethod = $method;
	if (!fillinpaths()) {
		$good = 0;
	}
	return $good;
}

sub fillinpaths {
	$subgood = 1;
	for my $path (keys %pathdefs) {
		my $value = $pathdefs{$path};
		$value =~ s/~/$ENV{HOME}/g;
		$value =~ s/S\{([^}]*)\}/subit($1)/sge;
		$path{$path} = $value;
	}
	return $subgood;
}

sub subit {
	my $var = shift;
	my $corruption = $scenario->{corruption};
	my $bruteforce = $scenario->{bruteforce};
	if ($var eq 'timestamp') {
		if (defined $timestamp) {
			return $timestamp;
		}
		else {
			return prettytime('program');
		}
	}
	elsif ($var eq 'experiment') {
		return $experiment;
	}
	elsif ($var eq 'redundancy') {
		return $theredundancy;
	}
	elsif ($var eq 'method') {
		return $themethod;
	}
	elsif ($var eq 'datafile') {
		return $thedatafile;
	}
	elsif ($var eq 'cd') {
		return sprintf "%s-%s", $corruption->{data}->{number}, $corruption->{data}->{burstlength};
	}
	elsif ($var eq 'cb') {
		return sprintf "%s-%s", $corruption->{backup}->{number}, $corruption->{backup}->{burstlength};
	}
	elsif ($var eq 'ccd') {
		return sprintf "%s-%s", $corruption->{datachk}->{number}, $corruption->{datachk}->{burstlength};
	}
	elsif ($var eq 'ccb') {
		return sprintf "%s-%s", $corruption->{backupchk}->{number}, $corruption->{backupchk}->{burstlength};
	}
	elsif ($var eq 'bfrepair') {
		return sprintf "%d", $bruteforce->{repair};
	}
	elsif ($var eq 'bfrestore') {
		return sprintf "%d", $bruteforce->{restore};
	}
	elsif ($var eq 'datafiles') {
		return join('-', sort(keys(%datafile)));
	}
	else {
		$subgood = 0;
		return 'S{'.$var.'}';
	}
}

sub timestamp {
	my $mark = shift;
	@{$time{$mark}} = gettimeofday();
}

sub prettytime {
	my $mark = shift;
	my @time = localtime $time{$mark}->[0];
	return sprintf "%04d-%02d-%02dT%02d-%02d-%02d", $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1], $time[0];
}

sub elapsed {
	my $mark = shift;
	my $elapsed = tv_interval($time{$mark});
	my $seconds = $elapsed;
	my $minutes;
	my $hours;
	if ($seconds > 60) {
		$seconds = int($seconds + 0.5);
		$minutes = int($seconds / 60);
		$seconds = $seconds % 60;
	}
	if ($minutes > 60) {
		$hours = int($minutes / 60);
		$minutes = $minutes % 60;
	}
	my $resultstring = '';
	if (defined $hours) {
		$resultstring .= sprintf "%3d:", $hours;
	}
	if (defined $minutes) {
		$resultstring .= sprintf "%02d:", $minutes;
	}
	if ($seconds == int($seconds)) {
		$resultstring .= sprintf "%02d   ", $seconds;
	}
	else {
		$resultstring .= sprintf "%5.2f", $seconds;
	}
	return sprintf "%12s", $resultstring;
}

sub fname {
	my $path = shift;
	$path =~ s/'//g;
	my ($fname) = $path =~ m/([^\/]*)$/;
	$fname =~ s/=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}//;
	return $fname;
}

sub trim {
	my $str = shift;
	return join(' ', map {fname($_)} split(/ /, $str));
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
		if ($kind or ($opt_verbose > 1)) {
			print STDERR $text;
		}
		if (defined $lh) {
			print $lh $text;
		}
	}
}

sub openwrite {
	my $file = shift;
	my $fh = FileHandle->new;
	if (!$fh->open("> $file")) {
		msg(-2, sprintf("Cannot write file [%s]", $file));
		return 0;
	}
	return $fh;
}

sub closefile {
	my $href = shift;
	close $$href;
	$$href = undef;
}

sub makedir {
	my $dir = shift;
	if (system("mkdir -p $dir")) {
		msg(-2, sprintf("Cannot create directory [%s]", $dir));
		return 0;
	}
	return 1;
}

sub dummy {
	1;
}

sub main {
	my $good = 1;
	timestamp('program');
	msg(1, sprintf("%s %-21s = starting", elapsed('program'), 'PROGRAM'));
	for (1) {
		if (!init()) {
			$good = 0;
			next;
		}
		if (!actions()) {
			$good = 0;
			next;
		}
	}
	msg(1, sprintf("%s %-21s = finished with GOOD=%d", elapsed('program'), 'PROGRAM', $good));
	return $good;
}

exit !main();
