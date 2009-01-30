#!./miniperl
use strict;
use warnings;
use Config;

# This script acts as a simple interface for building extensions.
# It primarily used by the perl Makefile:
#
# d_dummy $(dynamic_ext): miniperl preplibrary FORCE
# 	@$(RUN) ./miniperl make_ext.pl --target=dynamic $@ MAKE=$(MAKE) LIBPERL_A=$(LIBPERL)
#
# It may be deleted in a later release of perl so try to
# avoid using it for other purposes.

my (%excl, %incl, %opts, @extspec, @passthrough);

foreach (@ARGV) {
    if (/^!(.*)$/) {
	$excl{$1} = 1;
    } elsif (/^\+(.*)$/) {
	$incl{$1} = 1;
    } elsif (/^--([\w\-]+)$/) {
	$opts{$1} = 1;
    } elsif (/^--([\w\-]+)=(.*)$/) {
	$opts{$1} = $2;
    } elsif (/^--([\w\-]+)=(.*)$/) {
	$opts{$1} = $2;
    } elsif (/=/) {
	push @passthrough, $_;
    } else {
	push @extspec, $_;
    }
}

my $target   = $opts{target};
my $extspec  = $extspec[0];
my $makecmd  = shift @passthrough; # Should be something like MAKE=make
my $passthru = join ' ', @passthrough; # allow extra macro=value to be passed through
print "\n";

# Previously, $make was taken from config.sh.  However, the user might
# instead be running a possibly incompatible make.  This might happen if
# the user types "gmake" instead of a plain "make", for example.  The
# correct current value of MAKE will come through from the main perl
# makefile as MAKE=/whatever/make in $makecmd.  We'll be cautious in
# case third party users of this script (are there any?) don't have the
# MAKE=$(MAKE) argument, which was added after 5.004_03.
my $make;
if (defined($makecmd) and $makecmd =~ /^MAKE=(.*)$/) {
	$make = $1;
}
else {
	print "ext/util/make_ext:  WARNING:  Please include MAKE=\$(MAKE)\n";
	print "\tin your call to make_ext.  See ext/util/make_ext for details.\n";
	exit(1);
}

# fallback to config.sh's MAKE
$make ||= $Config{make} || $ENV{MAKE};
my $run = $Config{run};
$run = '' if not defined $run;
$run .= ' ' if $run ne '';;

if (!defined($extspec) or $extspec eq '')  {
	print "make_ext: no extension specified\n";
	exit(1);
}

# The Perl Makefile.SH will expand all extensions to
#	lib/auto/X/X.a  (or lib/auto/X/Y/Y.a if nested)
# A user wishing to run make_ext might use
#	X (or X/Y or X::Y if nested)

# canonise into X/Y form (pname)

my $pname = $extspec;
if ($extspec =~ /^lib/) {
	# Remove lib/auto prefix and /*.* suffix
	$pname =~ s{^lib/auto/}{};
	$pname =~ s{[^/]*\.[^/]*$}{};
}
elsif ($extspec =~ /^ext/) {
	# Remove ext/ prefix and /pm_to_blib suffix
	$pname =~ s{^ext/}{};
	$pname =~ s{/pm_to_blib$}{};
}
elsif ($extspec =~ /::/) {
	# Convert :: to /
	$pname =~ s{::}{\/}g;
}
elsif ($extspec =~ /\..*o$/) {
	$pname =~ s/\..*o//;
}

my $mname = $pname;
$mname =~ s!/!::!g;
my $depth = $pname;
$depth =~ s![^/]+!..!g;
my $makefile = "Makefile";

if (not -d "ext/$pname") {
	print "\tSkipping $extspec (directory does not exist)\n";
	exit(0); # not an error ?
}

if ($Config{osname} eq 'catamount') {
	# Snowball's chance of building extensions.
	print "This is $Config{osname}, not building $mname, sorry.\n";
	exit(0);
}

print "\tMaking $mname ($target)\n";

chdir("ext/$pname");

# check link type and do any preliminaries.  Valid link types are
# 'dynamic', 'static', and 'static_pic' (the last one respects
# CCCDLFLAGS such as -fPIC -- see static_target in the main Makefile.SH)
if ($target eq 'dynamic') {
	$passthru = "LINKTYPE=dynamic $passthru";
	$target   = 'all';
}
elsif ($target eq 'static') {
	$passthru = "LINKTYPE=static CCCDLFLAGS= $passthru";
	$target   = 'all';
}
elsif ($target eq 'static_pic') {
	$passthru = "LINKTYPE=static $passthru";
	$target   = 'all';
}
elsif ($target eq 'nonxs') {
	$target   = 'all';
}
elsif ($target =~ /clean$/) {
}
elsif ($target eq '') {
	print "make_ext: no make target specified (eg static or dynamic)\n";
	exit(1);
}
else {
	# for the time being we are strict about what make_ext is used for
	print "make_ext: unknown make target '$target'\n";
	exit(1);
}


if (not -f $makefile) {
	if (-f "Makefile.PL") {
		my $cross = $opts{cross} ? ' -MCross' : '';
		system("${run}../$depth/miniperl -I../$depth/lib$cross Makefile.PL INSTALLDIRS=perl INSTALLMAN3DIR=none PERL_CORE=1 $passthru");
	}
	# Right. The reason for this little hack is that we're sitting inside
	# a program run by ./miniperl, but there are tasks we need to perform
	# when the 'realclean', 'distclean' or 'veryclean' targets are run.
	# Unfortunately, they can be run *after* 'clean', which deletes
	# ./miniperl
	# So we do our best to leave a set of instructions identical to what
	# we would do if we are run directly as 'realclean' etc
	# Whilst we're perfect, unfortunately the targets we call are not, as
	# some of them rely on a $(PERL) for their own distclean targets.
	# But this always used to be a problem with the old /bin/sh version of
	# this.
	my $suffix = '.sh';
	foreach my $clean_target ('realclean', 'veryclean') {
		my $file = "../$depth/$clean_target$suffix";
		open my $fh, '>>', $file or die "open $file: $!";
		# Quite possible that we're being run in parallel here.
		# Can't use Fcntl this early to get the LOCK_EX
		flock $fh, 2 or warn "flock $file: $!";
		if ($^O eq 'VMS') {
			# Write out DCL here
		} elsif ($^O eq 'MSWin32') {
			# Might not need anything here.
		} else {
			print $fh <<"EOS";
chdir ext/$pname
if test ! -f $makefile -a -f Makefile.old; then
    echo "Note: Using Makefile.old"
    make -f Makefile.old $clean_target MAKE=$make $passthru
else
    if test ! -f $makefile ; then
	echo "Warning: No Makefile!"
    fi
    make $clean_target MAKE=$make $passthru
fi
chdir ../$depth
EOS
		}
		close $fh or die "close $file: $!";
	}
}

if (not -f $makefile) {
	print "Warning: No Makefile!\n";
}

if ($target eq 'clean') {
}
elsif ($target eq 'realclean') {
}
else {
	# Give makefile an opportunity to rewrite itself.
	# reassure users that life goes on...
	system( "$run$make config MAKE=$make $passthru" )
	  and print "$make config failed, continuing anyway...\n";
}

system "$run$make $target MAKE=$make $passthru" and exit $?;
