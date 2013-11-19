#!/usr/bin/perl
use bytes;
use strict;
use warnings;
no warnings "uninitialized";
no strict "refs";

use Getopt::Long qw(:config no_ignore_case);

=head1 DESCRIPTION

Gather data from experiments

=cut

# BEGIN configuration section

my $tablename = 'summary.txt';
my $chartname = 'chartdata.txt';

my $sep = "\t";

# logging and reporting

my @kindrep = (
	'Error',
	'Warning',
	'Info',
	undef,
);

my %methodorder = (
	md5_16	=> 1,
	crc_32	=> 2,
	md5_32	=> 3,
	md5_64	=> 4,
	md5		=> 5,
	sha256	=> 6,
);

# END configuration section

my $opt_verbose = 0;
my @activebases = ();

my $base;

my $rbase;
my @experiments = ();
my $experiment;

my $ebase;
my @bruteforces = ();
my $bruteforce;

my $bbase;
my @timestamps = ();
my $timestamp;

my $tbase;
my @datafiles = ();
my $datafile;

my $dbase;
my @corruptions = ();
my $corruption;

my $cbase;
my @logs = ();
my $log;

my @data;
my %chart;
my %rmethod;
my %sortorder = ();

=head2 Command line

	./gather.pl [-v] [--base reportbasedir]

where 
	-v			verbose rsync, if twice: verbose all
	--base		base directory of the reports

=cut

sub getcommandline {
	my $checkarg = 1;

	if (!GetOptions(
		'verbose|v+' => \$opt_verbose,
		'base|b=s@{,}' => \&checkarg,
	)) {
		$checkarg = 0;
	}
	if (!scalar @activebases) {
		msg(-2, sprintf("No report base chosen. Choose at least one existing report base."));
		$checkarg = 0;
	}
	return $checkarg;
}

sub checkarg {
	my ($name, $value, $hashvalue) = @_;
	for (1) {
		if ($name eq 'base') {
			if (!-d $value) {
				msg(-2, sprintf("Directory [%s] does not exist."));
			}
			else {
				push @activebases, $value;
			}
			next;
		}
	}
}

sub report {
	my $good = 1;
	for my $givenbase (@activebases) {
		$base = $givenbase;
		if (!reportbase()) {
			$good = 0;
		}
	}
	return $good;
}

sub reportbase {
	msg(1, $base);
	$rbase = "$base/report";
	if (!opendir(D, $rbase)) {
		msg(-2, "Cannot read directory [$rbase]");
		return 0;
	}
	my $tablefile = "$base/$tablename";
	if (!open(DF, ">$tablefile")) {
		msg(-2, "Cannot write data file [$tablefile]");
		return 0;
	}
	my $chartfile = "$base/$chartname";
	if (!open(CF, ">$chartfile")) {
		msg(-2, "Cannot write chart file [$chartfile]");
		return 0;
	}
	my @items = readdir D;
	closedir D;

	my $good = 1;
	@data = ();
	@experiments = ();
	for my $item (@items) {
		if ($item !~ m/^\./ and -d "$rbase/$item") {
			push @experiments, $item;
		}
	}
	for my $givenexperiment (@experiments) {
		$experiment = $givenexperiment;
		if (!reportexperiment()) {
			$good = 0;
		}
	}
	printf DF "%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s$sep%s\n",
		'experiment',
		'bfrepair',
		'bfrestore',
		'timestamp',
		'datafile',
		'cdn',
		'cdl',
		'ccdn',
		'ccdl',
		'cbn',
		'cbl',
		'ccbn',
		'ccbl',
		'redundancy',
		'method',
		'timerepair',
		'fw',
		'ccw',
		'cok',
		'cambi',
		'cambi%',
		'cfail',
		'cfail%',
		'ctotal',
		'timerestore',
		'fm',
		'rcw',
		'rok',
		'rambi',
		'rambi%',
		'rfail',
		'rfail%',
		'rtotal',
		'dtouched',
		'dincorrect',
		'dproblems',
	;
	for my $row (@data) {
		printf DF "%s$sep%d$sep%d$sep%s$sep%s$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%s$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%d$sep%s$sep%s\n", @$row;
	}
	close DF;

	for my $kind (sort keys %chart) {
		print CF printchart($kind);
	}
	close CF;
	return $good;
}

sub printchart {
	my $kind = shift;
	my $data = $chart{$kind};
	my $result = "$kind\n";
	$result .= printheader();
	for my $series (sort keys %$data) {
		$result .= printrows($series, $data->{$series}, $sortorder{$kind}->{$series});
	}
	$result .= "\n";
	return $result;
}

sub printheader {
	my $rootinfo = shift;
	my $result = sprintf "\t%s", $rootinfo;
	my $result1 = "\t";
	for my $r (sort {$a <=> $b} keys %rmethod) {
		my $ms = $rmethod{$r};
		my $nms = scalar keys %$ms;
		$result .= sprintf "\t\t%s%s", $r, "\t" x ($nms - 2); 
		for my $m (sort {$methodorder{$a} <=> $methodorder{$b}} keys %$ms) {
			$result1 .= sprintf "\t%s", $m;
		}
	}
	$result .= "\n\t" . $result1 . "\n";
	return $result;
}

sub printrows {
	my ($series, $data, $desc) = @_;
	my $result = sprintf "\t%s", $series;
	my $sep = '';
	my @keys;
	if ($desc) {
		@keys = sort {$b cmp $a} keys %$data;
	}
	else {
		@keys = sort keys %$data;
	}
	for my $exp (@keys) {
		$result .= printrow($exp, $data->{$exp}, $sep);
		$sep = "\t";
	}
	return $result;
}

sub printrow {
	my ($exp, $data, $sep) = @_;
	my $result = sprintf "$sep\t%s", $exp;
	for my $r (sort {$a <=> $b} keys %rmethod) {
		my $ms = $rmethod{$r};
		my $nms = scalar keys %$ms;
		if (!exists $data->{$r}) {
			$result .= "\t" x $nms;
			next;
		}
		for my $m (sort {$methodorder{$a} <=> $methodorder{$b}} keys %$ms) {
			if (!exists $data->{$r}->{$m}) {
				$result .= "\t";
				next;
			}
			my $valueinfo = $data->{$r}->{$m};
			my @timestamps = sort keys %$valueinfo;
			$result .= sprintf "\t%s", $valueinfo->{$timestamps[$#timestamps]};
		}
	}
	$result .= "\n";
	return $result;
}

#	$chart{$kind}->{$series}->{$experiment}->{$redundancy}->{$method}->{$timestamp} = $value;

sub reportexperiment {
	msg(1, "\t$experiment");
	$ebase = "$rbase/$experiment";
	if (!opendir(D, $ebase)) {
		msg(-2, "Cannot read directory [$ebase]");
		return 0;
	}
	my @items = readdir D;
	closedir D;

	my $good = 1;
	@bruteforces = ();
	for my $item (@items) {
		if ($item !~ m/^\./ and -d "$ebase/$item") {
			push @bruteforces, $item;
		}
	}
	for my $givenbruteforce (@bruteforces) {
		$bruteforce = $givenbruteforce;
		if (!reportbruteforce()) {
			$good = 0;
		}
	}
	return $good;
}

sub reportbruteforce {
	msg(1, "\t\t$bruteforce");
	$bbase = "$ebase/$bruteforce";
	if (!opendir(D, $bbase)) {
		msg(-2, "Cannot read directory [$bbase]");
		return 0;
	}
	my @items = readdir D;
	closedir D;

	my $good = 1;
	@timestamps = ();
	for my $item (@items) {
		if ($item !~ m/^\./ and -d "$bbase/$item") {
			push @timestamps, $item;
		}
	}
	for my $giventimestamp (@timestamps) {
		$timestamp = $giventimestamp;
		if (!reporttimestamp()) {
			$good = 0;
		}
	}
	return $good;
}

sub reporttimestamp {
	msg(1, "\t\t\t$timestamp");
	$tbase = "$bbase/$timestamp";
	if (!opendir(D, $tbase)) {
		msg(-2, "Cannot read directory [$tbase]");
		return 0;
	}
	my @items = readdir D;
	closedir D;

	my $good = 1;
	@datafiles = ();
	for my $item (@items) {
		if ($item !~ m/^\./ and -d "$tbase/$item") {
			push @datafiles, $item;
		}
	}
	for my $givendatafile (@datafiles) {
		$datafile = $givendatafile;
		if (!reportdatafile()) {
			$good = 0;
		}
	}
	return $good;
}

sub reportdatafile {
	msg(1, "\t\t\t\t$datafile");
	$dbase = "$tbase/$datafile";
	if (!opendir(D, $dbase)) {
		msg(-2, "Cannot read directory [$dbase]");
		return 0;
	}
	my @items = readdir D;
	closedir D;

	my $good = 1;
	@corruptions = ();
	for my $item (@items) {
		if ($item !~ m/^\./ and -d "$dbase/$item") {
			push @corruptions, $item;
		}
	}
	for my $givencorruption (@corruptions) {
		$corruption = $givencorruption;
		if (!reportcorruption()) {
			$good = 0;
		}
	}
	return $good;
}

sub reportcorruption {
	msg(1, "\t\t\t\t\t$corruption");
	$cbase = "$dbase/$corruption";
	if (!opendir(D, $cbase)) {
		msg(-2, "Cannot read directory [$cbase]");
		return 0;
	}
	my @items = readdir D;
	closedir D;

	my $good = 1;
	@logs = ();
	for my $item (@items) {
		if ($item !~ m/^\./ and -f "$cbase/$item" and $item =~ m/\.exp\.txt$/) {
			push @logs, $item;
		}
	}
	for my $givenlog (@logs) {
		$log = $givenlog;
		if (!reportlog()) {
			$good = 0;
		}
	}
	return $good;
}

sub reportlog {
	msg(1, "\t\t\t\t\t\t$log");
	my $logfile = "$cbase/$log";
	if (!open(LF, $logfile)) {
		msg(-2, "Cannot read file [$logfile]");
		return 0;
	}
	my @lines = <LF>;
	chomp @lines;
	close LF;

	my $good = 1;
	my ($bfrepair, $bfrestore) = split '-', $bruteforce;
	my ($cdn, $cdl, $ccdn, $ccdl, $cbn, $cbl, $ccbn, $ccbl) = split '-', $corruption;
	my ($redundancy, $method) = $log =~ m/^([0-9]+)-([^.]+)/;
	my (
		$tcb, $fw, $ccw,
		$tce, $cok, $cambi, $cfail, $ctotal,
		$trb, $fm, $rcw,
		$tre, $rok, $rambi, $rfail, $rtotal,
		$dtouched, $dincorrect, $dproblems
	);
	$rmethod{$redundancy}->{$method} = 1;

	for my $line (@lines) {
	# REPAIR start line
		if (!defined $tcb) {
        	($tcb, $fw, $ccw) = $line =~ m/^\s*([0-9.:]+)\s*REPAIR.*?- block frame width ([0-9]+), max checksum distance ([0-9]+),/;
			if (defined $tcb) {
				next;
			}
		}
	# REPAIR end line
		if (!defined $tce) {
    		($tce, $cok, $cambi, $cfail, $ctotal) = $line =~ m/^\s*([0-9.:]+)\s*REPAIR.*?- ([0-9]+) ok \(([0-9]+) ambi\), ([0-9]+) failure, total ([0-9]+),/;
			if (defined $tce) {
				next;
			}
		}
	# RESTORE start line
		if (!defined $trb) {
        	($trb, $fm, $rcw) = $line =~ m/^\s*([0-9.:]+)\s*RESTORE.*?- block mask width ([0-9]+), max checksum distance ([0-9]+),/;
			if (defined $trb) {
				next;
			}
		}
	# RESTORE end line
		if (!defined $tre) {
    		($tre, $rok, $rambi, $rfail, $rtotal) = $line =~ m/^\s*([0-9.:]+)\s*RESTORE.*?- ([0-9]+) ok \(([0-9]+) ambi\), ([0-9]+) failure, total ([0-9]+),/;
			if (defined $tre) {
				next;
			}
		}
	# DIAG lines
		if (!defined $dtouched) {
			($dtouched) = $line =~ m/\s*[0-9.:]+\s*DIAG.*?- ([0-9]+) blocks touched/;
			if (defined $dtouched) {
				next;
			}
		}
		if (!defined $dincorrect) {
			($dincorrect) = $line =~ m/\s*[0-9.:]+\s*DIAG.*?- ([0-9]+) blocks incorrect/;
			if (defined $dincorrect) {
				next;
			}
		}
		if (!defined $dproblems) {
			($dproblems) = $line =~ m/\s*[0-9.:]+\s*DIAG.*?- ([0-9]+) problems/;
			if (defined $dproblems) {
				next;
			}
		}
	}

	my $timerepair = interval($tce, $tcb);
	my $timerestore = interval($tre, $trb);
	my $cfailperc = $ctotal ? int(100 * $cfail / $ctotal + 0.5) : 100;
	my $cambiperc = $ctotal ? int(100 * $cambi / $ctotal + 0.5) : 100;
	my $rfailperc = $rtotal ? int(100 * $rfail / $rtotal + 0.5) : 100;
	my $rambiperc = $rtotal ? int(100 * $rambi / $rtotal + 0.5) : 100;

	for my $item (
		['c-diag', 'fail', $dproblems, 0],
		['c-restore', 'fail', $rfailperc, 0],
		['c-repair', 'fail', $cfailperc, 1],
		['p-restore', 'time', $timerestore, 0],
		['p-repair', 'time', $timerepair, 0],
	) {
		my ($kind, $series, $value, $desc) = @$item;
		$chart{$kind}->{$series}->{$experiment}->{$redundancy}->{$method}->{$timestamp} = $value;
		$sortorder{$kind}->{$series} = $desc;
	}

	push @data, [
		$experiment,
		$bfrepair,
		$bfrestore,
		$timestamp,
		$datafile,
		$cdn,
		$cdl,
		$ccdn,
		$ccdl,
		$cbn,
		$cbl,
		$ccbn,
		$ccbl,
		$redundancy,
		$method,
		$timerepair,
		$fw,
		$ccw,
		$cok,
		$cambi,
		$cambiperc,
		$cfail,
		$cfailperc,
		$ctotal,
		$timerestore,
		$fm,
		$rcw,
		$rok,
		$rambi,
		$rambiperc,
		$rfail,
		$rfailperc,
		$rtotal,
		$dtouched,
		$dincorrect,
		$dproblems,
	];
	return $good;
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
	}
}

sub interval {
	my ($end, $start) =@_;
	return int(getseconds($end) - getseconds($start) + 0.5);
}

sub getseconds {
	my $rep = shift;
	my @comps = reverse split /:/, $rep;
	return 3600 * $comps[2] + 60 * $comps[1] + $comps[0];
}

sub dummy {
	1;
}

sub main {
	my $good = 1;
	for (1) {
		if (!getcommandline()) {
			$good = 0;
			next;
		}
		if (!report()) {
			$good = 0;
			next;
		}
	}
	msg(1, sprintf("Reporting done, GOOD=%d", $good));
	return $good;
}

exit !main();
