ABOUT
=====

The idea of using checksums for error **recovery** is sketched in my `DANS Lab: Bit Rot and Recovery <http://demo.datanetworkservice.nl/mediawiki/index.php/Bit_Rot_and_Recovery>`_.

The code is here (Perl).

There is a program for checksumming files, verifying, repairing and restoring: *checksum.pl*.

Then there is a setup to do experiments: *perfset.pl* creates a pool of corrupt file and organizes tests of various checksum methods.

The question is: wich checksum methods *perform* best in the brute force search for the original byte sequence?

In order to make file corrupt, you can run *corrupt.pl* with a variety of parameters.

To gather the results of a series of experiments, use *gather.pl*. It creates a csv file, that you can use to create nice graphics
in a spreadsheet program.
