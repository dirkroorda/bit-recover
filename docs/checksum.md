# checksum.pl

## Description
This tool is an instrument in bit preservation of (large) files.
It is estimated that if one reads 10 TB from disk, 1 bit will be in error.
Also, when 1 TB is stored for a year without touching it, some bits might
be damaged by random physical events such as radiation.

In order to bit-peserve large files for longer periods of time (years, decades),
it becomes important to guard against data loss.

While there is no profound solution to this problem, the following stratgegy
counts as best practice.

* Make several copies
* Divide the file and their copies in chuncks and compute checksums of the chunks
* periodically check checksums and restore damaged blocks from copies where the corresponding
  block is undamaged.

*Checksum.pl* is a script to compute checksums for files, to verify checksums, and
to repair corrupted file by means of brute force searching, or if that is not feasible,
by restoring from backup copies, even if those are corrupt themselves. 
It works even when the checksums themselves are corrupt.

It al depends on the damage being not too big.

## Usage
Call the script like this:

```sh
./checksum.pl [-v] [-m method] [-t task]* [--conf kind=path]* --data kind=path [backupfile] [origfile] [corruptfile]
```

where :

```
	-v			verbose operation
	method		key of %config_checksum
	task		member of:
					generate
					verify
					repair
					restore
					restore_ambi_no
					restore_ambi_only
					execute_repair
					execute_restore
					diag

	conf:
		kind	key of %files
		path	will replace the name value in %files

	data	
		kind	key of %datafile
		path	path to a file on the file system
```


This script can generate checksums, verify them, and perform repair and restore from backup.
The verification step produces a file with mismatches, if present.
The repair and restore steps look at the file with mismatches and then try to find out how to repair
those mismatches. The result is writen to a file with instructions.
An execute step reads those instructions and executes them, actually changing the data file.
The checksum files are not modified. They can easily be recomputed again.

All intermediate files (also those with the generated checksums) are binary:
all data consists of fixed length strings, 64-bit integers, or fixed-size blocks of binary data.
All these files have a header, indicating the checksum method used, as well as the data block size and the
checksum length.

With arguments like `file:kind=path`
you can overrule the locations and names (but not extensions) of all files that are read and written to.
The kind part must occur as key in the *%files* hash.

## Generating

Command:

```sh
./checksum.pl file
```

Generates checksums for (large) files, block by block. The size of a block is configured to 1000 bytes.
The main reason to keep it fairly small is to be able to do brute force guessing when a checksum is found not
to agree anymore with a datablock.

By generating many slight bit errors in the datablock as well as the checksum, and then searching for a valid
combination of datablock and checksum, we can be nearly completely sure that we have the original datablock and checksum
back.

The file with checksums has the same name as the input file, but with *.chk* appended to it. 

## Verifying

Command:

```sh
./checksum.pl -v file
```

Verifies given checksums. It expects next to the input file a *file.chk* with checksums, in the format indicated
above. It then extracts from file each block as specified in *file.chk*, computes its checksum and compares it 
to the given checksum.

If there are checksum errors, references to the blocks in error are written to an error file, with name *file.x* .
This file contains records of mismatch information.
Such a record consists of just the block number, the given checksum, and the computed checksum.

If there are no errors, the *file.x* will not be present. If it existed, it will be deleted.

## Repairing

Command:

```sh
./checksum.pl -c file
```

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

The repair instructions are written to *file.ri*

## Restoring

Command:

```sh
./checksum.pl -r[a|A] file file-backup
```

Compares blocks and checksums of data and backup. The bit positions where they differ, will be varied among all
possibilities. The checksums are stored in a hash for easy lookup. Then the blocks will be generated on the fly.
So even if the backup is damaged, and even if the checksums are all damaged, it is still possible by brute force
search to find the original data back. If data and backup differ in less than 20 bits per block, there are only a million
possibilities per block to be searched.
If called with -rA only the blocks for which repair found multiple hits will be restored (not the ones without hits)
If called with -ra both the blocks for which repair found multiple hits and no hits will be restored

The restore instructions are written *file.rib*

## Executing

Commands:

```sh
./checksum.pl -ec file
./checksum.pl -er file
```

Executes the repair resp. restore instructions in *file.ri* resp. *file.rib*
All information needed from the backup file is already in the instruction file, so the backup file itself is not 
needed here. The work has been done in the previous steps, this step only performs the write actions in the file.

## Diagnostics

Command:

```sh
./checksum.pl -dia file backupfile origfile corruptfile
```

Creates a diagnostic report of the repair and restore instructions. It takes as second argument the backup file and as 
third argument the original file and as fourth argument the unrestored/unrepaired corrupted file.
It gives all info about the blocks which have not been restored correctly.
On the basis of this information it shows which instructions helped to correctly get the original back,
and which instructions were faulty.

## Author

Dirk Roorda,
[Data Archiving and Networked Services (DANS)](https://www.dans.knaw.nl)

2013-03-29
dirk.roorda@dans.knaw.nl

See also [DANS Lab Bit rot and recovery](http://demo.datanetworkservice.nl/mediawiki/index.php/Bit_Rot_and_Recovery)

## Configuration
In order to compare performance between md5 and sha256 hashing we provide two standard configurations, which can be
invoked by the command line flag ``-m``:

```
	-m md5
	-m sha256
```

invoke the md5 and the sha256 checksum algorithms respectively.
The default parameter values for these methods are loaded. It remains possible to overrule these values
by means of additional flags on the command line.

The default checksum mode is sha256. 

## Implementation details

### Looking for hits
When measuring how close a "hit" is to the actual situation, the number of different bits in the checksums
and in the blocks are counted. However, differences in the checksum count much more than differences in the blocks.

Bit differences in the checksums are far less probable than bit differences in the blocks, because blocks are larger. 
Moreover, if checksums are very different, it is an indication of tampering: a new checksum has been computed for a slightly altered block.
So by default we multiply the checksum bit distance by the `$data_checksum_ration`.
In addition, you can configure to increase or decrease this effect by multiplying with the `$check_diff_penalty` which is by default 1.

We compare hits with the foreground file, not with the backup.
We want a hit that is closest to the foreground, since the foreground has been always under our control, and the backup has been far less in our control.

We want to keep the search effort constant for the different checksum methods. Depending on the blocksize determined by the checksum method, we can
set the search parameters in such a way that the prescribed number of search operations will be used.

### Binary files and headers
Every binary non-data file we read, is a file generated by this program. Such a file has a header.
It will be read and written by the following two functions.
It has the format:

```
	a8 a8 L L L L
```

where:

```
	a8 is arbitrary binary data of 8 bytes. Reserved for a string indicating the checksum method
	a8 is arbitrary binary data of 8 bytes. Reserved for a string indicating the checksum method
	L is a long integer (32 bits = 4 bytes), indicating the checksum size
	L is a long integer (32 bits = 4 bytes), indicating the checksum size
	L is a long integer (32 bits = 4 bytes), indicating the block size
	L is a long integer (32 bits = 4 bytes), indicating the block size
```

All together the header is 32 bytes = 256 bits

The header could be damaged. We assume the checksum size and the block size are powers of two.
If one of them does not appear a power of two, choose the other. If both are not powers of two, we are stuck.
If both are powers of two but different, we are also stuck.
Likewise, we choose between the values encountered for the checksummethod.

### Reading and Writing files

Opens files for reading, writing, and read-writing.
Uses the specification created in the init() function.
Returns a file handle in case of succes.
The file handle is meant to be stored in global variables.
So more than one routine can easily read and write the same file.

### Repair block

This function implements a main step: Repair a single block
We apply ditherings progressively, in rounds corresponding to the frame length n of the dithering.
We start with n = 0, then n = 1 and so on.
So the smaller disturbances will be checked first, and we assume that bigger disturbances do not compete with smaller ones.
If there are hits in a round, the next rounds will be skipped.

### Restore block

now generate the set by creating all possible bit values at the positions where $str1 and $str2 differ 
in order to optimize the search process, we want to search in such a way that we do cases first where bits are taken
consecutively from the data version or the backup version.
The reason is that errors come in bursts. Hence, if backup and data differ in bit i and bit i+1, both bits are likely to be correct in either backup
or in data. It is much less likely that bit i is correct in data and bit i+1 in backup, or vice versa.
So if the max number of brute force operations does not permit full traversal, we do a partial traversal with the most likely suspects first.
This will increase the change of finding a good restore.

So we generate all possibile bit strings for the difference mask. We will xor the bits in the mask with the corresponding bits in the data.
So we should try bitstrings first with minimal alterations between 1s and 0s.

### Dithering

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

### Masking

This is the technique used for restoring blocks.
When the corresponding block from the backup is fetched, and we have the data block,
then in the most general case we do not know which block is right.
They could be both wrong. Even the checksums could be all wrong.

We assume however, that the bits in which they agree are correct.

So me make a mask of the differing bits, and we create all bit variations in that mask.

We try them all out by brute force.

So there is good chance that we find a hit, even if all initial data is corrupted.

