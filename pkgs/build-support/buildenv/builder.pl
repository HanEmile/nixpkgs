#! @perl@ -w

use strict;
use Cwd 'abs_path';
use IO::Handle;
use File::Path;
use File::Basename;
use File::Compare;
use File::Slurp qw(read_file);
use JSON::PP;

STDOUT->autoflush(1);

my $nixAttrs = decode_json(read_file(".attrs.json"));
my $out = $nixAttrs->{outputs}->{out};

my @pathsToLink = @{$nixAttrs->{pathsToLink}};

sub isInPathsToLink {
    my $path = shift;
    $path = "/" if $path eq "";
    foreach my $elem (@pathsToLink) {
        return 1 if
            $elem eq "/" ||
            (substr($path, 0, length($elem)) eq $elem
             && (($path eq $elem) || (substr($path, length($elem), 1) eq "/")));
    }
    return 0;
}

# Returns whether a path in one of the linked packages may contain
# files in one of the elements of pathsToLink.
sub hasPathsToLink {
    my $path = shift;
    foreach my $elem (@pathsToLink) {
        return 1 if
            $path eq "" ||
            (substr($elem, 0, length($path)) eq $path
             && (($path eq $elem) || (substr($elem, length($path), 1) eq "/")));
    }
    return 0;
}

# Similar to `lib.isStorePath`
sub isStorePath {
    my $path = shift;
    my $storePath = "@storeDir@";

    return substr($path, 0, 1) eq "/" && dirname($path) eq $storePath;
}

# For each activated package, determine what symlinks to create.

my %symlinks;

# Add all pathsToLink and all parent directories.
#
# For "/a/b/c" that will include
# [ "", "/a", "/a/b", "/a/b/c" ]
#
# That ensures the whole directory tree needed by pathsToLink is
# created as directories and not symlinks.
$symlinks{""} = ["", 0];
for my $p (@pathsToLink) {
    my @parts = split '/', $p;

    my $cur = "";
    for my $x (@parts) {
        $cur = $cur . "/$x";
        $cur = "" if $cur eq "/";
        $symlinks{$cur} = ["", 0];
    }
}

sub findFiles;

sub findFilesInDir {
    my ($relName, $target, $ignoreCollisions, $checkCollisionContents, $priority) = @_;

    opendir DIR, "$target" or die "cannot open `$target': $!";
    my @names = readdir DIR or die;
    closedir DIR;

    foreach my $name (@names) {
        next if $name eq "." || $name eq "..";
        findFiles("$relName/$name", "$target/$name", $name, $ignoreCollisions, $checkCollisionContents, $priority);
    }
}

sub checkCollision {
    my ($path1, $path2) = @_;

    my $stat1 = (stat($path1))[2];
    my $stat2 = (stat($path2))[2];

    if ($stat1 != $stat2) {
        warn "different permissions in `$path1' and `$path2': "
           . sprintf("%04o", $stat1 & 07777) . " <-> "
           . sprintf("%04o", $stat2 & 07777);
        return 0;
    }

    return compare($path1, $path2) == 0;
}

sub findFiles {
    my ($relName, $target, $baseName, $ignoreCollisions, $checkCollisionContents, $priority) = @_;

    # The store path must not be a file
    if (-f $target && isStorePath $target) {
        die "The store path $target is a file and can't be merged into an environment using pkgs.buildEnv!";
    }

    # Urgh, hacky...
    return if
        $relName eq "/propagated-build-inputs" ||
        $relName eq "/nix-support" ||
        $relName =~ /info\/dir/ ||
        ( $relName =~ /^\/share\/mime\// && !( $relName =~ /^\/share\/mime\/packages/ ) ) ||
        $baseName eq "perllocal.pod" ||
        $baseName eq "log" ||
        ! (hasPathsToLink($relName) || isInPathsToLink($relName));

    my ($oldTarget, $oldPriority) = @{$symlinks{$relName} // [undef, undef]};

    # If target doesn't exist, create it. If it already exists as a
    # symlink to a file (not a directory) in a lower-priority package,
    # overwrite it.
    if (!defined $oldTarget || ($priority < $oldPriority && ($oldTarget ne "" && ! -d $oldTarget))) {
        $symlinks{$relName} = [$target, $priority];
        return;
    }

    # If target already exists as a symlink to a file (not a
    # directory) in a higher-priority package, skip.
    if (defined $oldTarget && $priority > $oldPriority && $oldTarget ne "" && ! -d $oldTarget) {
        return;
    }

    unless (-d $target && ($oldTarget eq "" || -d $oldTarget)) {
        if ($ignoreCollisions) {
            warn "collision between `$target' and `$oldTarget'\n" if $ignoreCollisions == 1;
            return;
        } elsif ($checkCollisionContents && checkCollision($oldTarget, $target)) {
            return;
        } else {
            die "collision between `$target' and `$oldTarget'\n";
        }
    }

    findFilesInDir($relName, $oldTarget, $ignoreCollisions, $checkCollisionContents, $oldPriority) unless $oldTarget eq "";
    findFilesInDir($relName, $target, $ignoreCollisions, $checkCollisionContents, $priority);

    $symlinks{$relName} = ["", $priority]; # denotes directory
}


my %done;
my %postponed;

sub addPkg {
    my ($pkgDir, $ignoreCollisions, $checkCollisionContents, $priority)  = @_;

    return if (defined $done{$pkgDir});
    $done{$pkgDir} = 1;

    findFiles("", $pkgDir, "", $ignoreCollisions, $checkCollisionContents, $priority);

    my $propagatedFN = "$pkgDir/nix-support/propagated-user-env-packages";
    if (-e $propagatedFN) {
        open PROP, "<$propagatedFN" or die;
        my $propagated = <PROP>;
        close PROP;
        my @propagated = split ' ', $propagated;
        foreach my $p (@propagated) {
            $postponed{$p} = 1 unless defined $done{$p};
        }
    }
}

# Symlink to the packages that have been installed explicitly by the
# user.
for my $pkg (@{$nixAttrs->{pkgs}}) {
    for my $path (@{$pkg->{paths}}) {
        addPkg($path,
               $nixAttrs->{ignoreCollisions},
               $nixAttrs->{checkCollisionContents},
               $pkg->{priority})
           if -e $path;
    }
}


# Symlink to the packages that have been "propagated" by packages
# installed by the user (i.e., package X declares that it wants Y
# installed as well).  We do these later because they have a lower
# priority in case of collisions.
my $priorityCounter = 1000; # don't care about collisions
while (scalar(keys %postponed) > 0) {
    my @pkgDirs = keys %postponed;
    %postponed = ();
    foreach my $pkgDir (sort @pkgDirs) {
        addPkg($pkgDir, 2, $nixAttrs->{"checkCollisionContents"}, $priorityCounter++);
    }
}

# Create the symlinks.
my $extraPrefix = $nixAttrs->{extraPrefix};
my $nrLinks = 0;
foreach my $relName (sort keys %symlinks) {
    my ($target, $priority) = @{$symlinks{$relName}};
    my $abs = "$out" . "$extraPrefix" . "/$relName";
    next unless isInPathsToLink $relName;
    if ($target eq "") {
        #print "creating directory $relName\n";
        mkpath $abs or die "cannot create directory `$abs': $!";
    } else {
        #print "creating symlink $relName to $target\n";
        symlink $target, $abs ||
            die "error creating link `$abs': $!";
        $nrLinks++;
    }
}


print STDERR "created $nrLinks symlinks in user environment\n";


my $manifest = $nixAttrs->{manifest};
if ($manifest) {
    symlink($manifest, "$out/manifest") or die "cannot create manifest";
}
