#!/usr/bin/perl

# (C) Richard Harman, 2010
# <perl-poorcase@richardharman.com>

use strict;
use warnings;
use Getopt::Long qw(:config pass_through);
use Cwd qw(abs_path);
use Pod::Usage;

$ENV{PATH} = "/bin:/usr/bin:/sbin:/usr/sbin";

my $opts = { "options" => "ro", };

GetOptions( $opts, "build", "destroy", "options=s", "name=s", "help|?" )
  or pod2usage( -exitval => 1, -verbose => 2 );

pod2usage(
    -msg     => "No build or destroy operation specified.",
    -verbose => 1,
    -exitval => 1
) unless ( defined( $opts->{build} ) || defined( $opts->{destroy} ) );
pod2usage(
    -msg     => "No device mapper base device name specified via --name",
    -verbose => 1,
    -exitval => 1
) unless ( defined( $opts->{name} ) );
pod2usage(
    -msg     => "Unknown --option $opts->{option}",
    -verbose => 1,
    -exitval => 1
) unless ( $opts->{options} eq "ro" or $opts->{options} eq "rw" );

if ( $opts->{options} eq "ro" ) {
    $opts->{readonly} = 1;
} elsif ( $opts->{options} eq "rw" ) {
    $opts->{readonly} = 0;
} else {
    pod2usage(
        -msg     => "Dazed and confused by --option $opts->{option}.  Use --option rw or --option ro",
        -verbose => 1,
        -exitval => 1
    );
}

my @files = map { abs_path($_) } @ARGV;

if ( $opts->{build} ) {
    my @mapping;
    print "Building array named '$opts->{name}' with:\n\t@files\n";
    foreach my $file ( sort { $a cmp $b } @files ) {
        open( LOSETUP, "-|", "losetup", "--show",
            $opts->{readonly} ? "-fr" : "-f", $file )
          or die "Couldn't run losetup ($!)";
        my $loopdev = <LOSETUP>;
        chomp $loopdev;
        close LOSETUP;
        my $size = ( stat($file) )[7];
        push @mapping,
          {
            filename => $file,
            size     => $size / 512,
            loopdev  => $loopdev,
          };
        printf "\tfile %s (%d 512 byte blocks) loopdev %s\n", $file,
          $size / 512, $loopdev;
    }

    my $table;
    my $offset = 0;
    foreach my $obj (@mapping) {
        $table .= sprintf( "%d %d linear %s 0\n",
            $offset, $obj->{size}, $obj->{loopdev} );
        $offset += $obj->{size};
    }
    print "\nBase Device Table: ($opts->{name})\n$table\n";
    open( DMSETUP, "|-", "dmsetup",
        $opts->{readonly} ? ( "-r", "create" ) : ("create"),
        $opts->{name} )
      or die "Couldn't create device-mapper device ($!)";
    print DMSETUP $table;
    close DMSETUP;
    print "Parsing partitions and creating devices:\n";
    open( PARTX, "-|", "partx", "-l", "/dev/mapper/$opts->{name}" )
      or die "Couldn't get partition table from partx! ($!)";
    my @partitions;

    while (<PARTX>) {
        chomp;
        my ( $num, $start_sect, $end, $length ) =
          ( $_ =~ m/#\s*([-\d]+):\s*([-\d]+?)-\s*([-\d]+)\s*\(\s*(\d+)\s*sect/ );

        # ignore empty/nonexistent partitions
        if ( $start_sect ne "0" && $end ne "-1" ) {
            push @partitions,
              { num => $num, start => $start_sect, length => $length };
        }
    }
    foreach my $partition (@partitions) {
        open( DMSETUP, "|-", "dmsetup", "-r", "create",
            $opts->{name} . $partition->{num} )
          or die "Couldn't create partition via dmsetup! ($!)";
        printf DMSETUP "0 %d linear /dev/mapper/%s %d\n",
          $partition->{length},
          $opts->{name}, $partition->{start};
        printf "Creating partition %d\n0 %d linear /dev/mapper/%s %d (%s%d)\n",
          $partition->{num},
          $partition->{length},
          $opts->{name}, $partition->{start}, $opts->{name},
          $partition->{num};
        close DMSETUP;
	if ($? >> 8 != 0) {
	  print "*** Error detected when attempting to create partition $partition->{num}! ***\n";
	}
    }
} elsif ( $opts->{destroy} ) {
    open( DMSETUP, "-|", "dmsetup", "ls" )
      or die "Couldn't get list of device mapper devices! ($!)";
    foreach (
        sort { $b cmp $a }
        grep { $_ =~ m/$opts->{name}(?:\d+)?\s*/ } <DMSETUP>
      )
    {
        chomp;
        my ($device) = ( $_ =~ m/^(\S+)\s/ );
        print "removing device mapper device: '$device'\n";
        system( "dmsetup", "remove", $device ) == 0
          or die "Couldn't remove device $device ($!)";
    }
    foreach my $file (@files) {
        open( LOSETUP, "-|", "losetup", "-j", $file )
          or die "Couldn't get loopback device listing for $file ($!)";
        my ($device) = ( <LOSETUP> =~ m/^([^:]+):/ );
        close LOSETUP;
        print "disassociating $device from $file\n";
        system( "losetup", "-d", $device ) == 0
          or die "Couldn't remove loopback device $device for file $file ($!)";
    }
}

=head1 NAME

poorcase - virtually map a split disk image back into a whole disk

=head1 SYNOPSIS

poorcase [options] [file ...]

 Options:
   --help       this help text
   --build      build a mapped image
   --destroy    destroy a previously mapped imave
   --name       the name of the device being created or destroyed
   --options    read-write or read-only mode

=head1 EXAMPLES

  poorcase --build   --name winxp_jdoe -o rw winxpjdoe.000 winxpjdoe.001 winxpjdoe.002 ... winxpjdoe.037
  poorcase --build   --name winxp_jdoe -o ro winxpjdoe.000 winxpjdoe.001 winxpjdoe.002 ... winxpjdoe.037

  poorcase --destroy --name winxp_jdoe -o rw winxpjdoe.000 winxpjdoe.001 winxpjdoe.002 ... winxpjdoe.037

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exit.

=item B<--build>

Assemble a device mapper device from a series of split disk image files.

=item B<--destroy>

Destroy (disassemble) a device mapper device previously assembled from split disk image files.

=item B<--name>

The name of the device in /dev/mapper to be built, and the base name of the partitions on it.

=item B<--options> B<-o>

The access mode to create the device in /dev/mapper.  Either "rw" for read-write, or "ro" for read-only.  Just like the mount command.  Defaults to read-only if not specified.

=back

=head1 DESCRIPTION

poorcase is a utility to virtually reconstruct a disk from split disk images usually produced as a result of disk imaging for forensic analysis.  These disk images are commonly split into sizes ranging from 650 megabytes to 4 gigabytes, then these files are loaded into a forensic analysis program such as EnCase, FTK, or SleuthKit.

There are a lot of open source utilities that can do some of the same things the above products can, but unfortunately they can't cope with disk images that have been split apart.  With poorcase, you can mount the filesystem and browse through it with utilities designed for picking apart metadata from that filesystem, such as the ntfs-3g utilities, debugfs, etc.

=head1 REQUIREMENTS

=over 8 

=item device mapper (dmsetup)

poorcase requires device mapper to virtually reconstruct the full disk image from the individual parts.

=item loopback devices (losetup)

poorcase uses loopback devices to turn files into block devices, used by device mapper.

=item partx

poorcase uses partx to read the reconstructed partition table, and "slice" the drive into individual partitions.

=back

=head1 TODO

I discovered a neat method to make a devicemapper device "copy on write" through device table hackery.  I may add future support for this, so that you can use Live View L<http://liveview.sourceforge.net/> or your preferred virtualization platform L<http://www.libvirt.org> on a read-only image keeping it forensically sound, but permitting the virtual machine to believe it is writing to the image.

=head1 AUTHOR

Richard G Harman Jr, C<< <perl-poorcase at richardharman.com> >>

=cut

!!'mtfnpy!!';
