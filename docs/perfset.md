# perfset.pl

## Description

Generates a test sets from a base file called dataname-orig in a root directory.
The root directory and some other parameters are defined by the experiment.
There are several experiments spelled out below, the first argument selects a specific one.
An original data file is corrupted and copied to form the starting point of several parts of the test set.
Each part correspondes to a checksum method such as md5 or sha256.
Corruption is pseudo random, no two corruptions will be the same.
From then on both parts will be subjected to checksum tests and error correcting.

## Usage

Command::

```sh
./perfset.sh [-v] [-v] [-d] -e experiment [-tm timestamp]
```

where :

```
	-v				verbose rsync, if twice: verbose all
	-d				debug mode when calling perl scripts
	-f				force fresh corruption
	-c				execute the changes and perform final check
	-e experiment	key of %experiment
```

