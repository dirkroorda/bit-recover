DESCRIPTION
===========
Corrupts the file with (burst)bit errors.
If level is given, it is the desired number of (burst)bit errors per TB.
If number is given, it is the desired absolute number of bit errors.

The bit errors are generated at independently randomly chosen positions.

It is also possible to generate burst errors of length at most nbits.
A burst error is a sequence of identical bits that will overwrite a sequence of equal length in the input file.
The length of the burst is determined randomly and independently but stays below the maximum length.
The value of the burst (zeroes or ones) will be determined randomly.

USAGE
=====
Command::

	./corrupt.pl [-s] [-b nbits] [-l level | -n number] --data file*

