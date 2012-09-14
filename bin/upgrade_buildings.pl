#!/usr/bin/perl
#
# Simple program for upgrading buildings on a planet.
# based on https://github.com/lemming552/Lacuna.git
# bin/upgrade_spaceports.pl
#

use strict;
use warnings;
use v5.10;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;
use Games::Lacuna::Client::Types qw( get_tags building_type_from_label meta_type );
use Getopt::Long qw(GetOptions);
use JSON;
#use Exception::Class;
use Try::Tiny;
use List::Util qw(min);
use List::MoreUtils qw(none);

use Data::Dumper;


  my %opts = (
        g => 0,
        h => 0,
        v => 0,
        maxlevel => 29,  # I know 30 is max, but for planets with a lot of spaceports, too much energy
        config => "lacuna.yml",
        dumpfile => "log/building_upgrades.js",
        station => 0,
        wait    => 60 * 24 * 60 * 60 *60,
  );

  GetOptions(\%opts,
    'g|gasgiant',
    'h|help',
    'v|verbose',
    'planet=s@',
    'config=s',
    'dumpfile=s',
    'maxlevel=i',
    'number=i',
    'wait=i',
  );

  usage() if $opts{h};

  #use Data::Dumper;
  #say Dumper(\%opts);

  my $glc = Games::Lacuna::Client->new(
    cfg_file => $opts{config} || "lacuna.yml",
    # debug    => 1,
  );

  my $json = JSON->new->utf8(1);
  $json = $json->pretty([1]);
  $json = $json->canonical([1]);
  #open(OUTPUT, ">", $opts{dumpfile}) || die "Could not open $opts{dumpfile} for writing.";

  my $status;
  my $empire = $glc->empire->get_status->{empire};
  print "Starting RPC: $glc->{rpc_count}\n";

## Get planets
my %planets = reverse %{ $empire->{planets} };
  #my %planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};
  #$status->{planets} = \%planets;
  my $short_time = $opts{wait} + 1;

my $keep_going = 1;
my $pname;
my @skip_planets;
do {
PNAME:for $pname (sort keys %planets) {
  if ($opts{planet}) {
      next PNAME if none { lc $pname eq lc $_ } @{ $opts{planet} };
  }

  print "Inspecting $pname\n";
  my $planet    = $glc->body(id => $planets{$pname});
  my $result    = $planet->get_buildings;
  my $buildings = $result->{buildings};

  my $station = $result->{status}{body}{type} eq 'space station' ? 1 : 0;
  if ($station) {
    push @skip_planets, $pname;
    next PNAME;
  }

  my ($sarr) = bstats($buildings, $station);
  my $seconds = $opts{wait} + 1;
  BLD:for my $bld (@$sarr) {

    printf "%7d %10s l:%2d x:%2d y:%2d\n",
           $bld->{id}, $bld->{name},
           $bld->{level}, $bld->{x}, $bld->{y};

    my $type = get_type_from_url($bld->{url});
    my $bldpnt = $glc->building( id => $bld->{id}, type => $type);

    if ( exists $bld->{pending_build} ) {
      $seconds = $bld->{pending_build}->{seconds_remaining};
      say qq( pending build for seconds: $seconds);
      ($seconds, $short_time) = seconds_check($seconds, $short_time);
       next BLD;
    }
    my $bldstat = "Bad";
    try {
      $bldstat = $bldpnt->upgrade();
      sleep(1);
    }
    catch {
      say qq(Upgrade failed: $_);
      if ( m/no room left in the build queue/) {
        next PNAME;
      }
      elsif (m/You must complete the pending build first/) {
        $seconds = $bld->{pending_build}->{seconds_remaining};
        say qq( pending seconds: $seconds);
        ($seconds, $short_time) = seconds_check($seconds, $short_time);
        next BLD;
      }
      else {
        next BLD;
      }
    };

    $seconds = $bldstat->{building}->{pending_build}->{seconds_remaining};
    ($seconds, $short_time) = seconds_check($seconds, $short_time);
    say qq( upgrade seconds: $seconds);
  }
  $status->{"$pname"} = $sarr;
  ($seconds, $short_time) = seconds_check($seconds, $short_time);
}
  say qq(Ending   RPC: $glc->{rpc_count});
  say qq(sleeping for $short_time seconds);
  sleep $short_time;
  $short_time = $opts{wait} + 1;
} while ($keep_going);

exit(0);
sub seconds_check {
  my ($seconds, $short_time) = @_;
  if ($seconds < $short_time) {
      $short_time = $seconds;
  }
  return($seconds, $short_time);
}
sub bstats {
  my ($bhash, $station) = @_;

  my $bcnt = 0;
  my $dlevel = $station ? 121 : 0;
  my @sarr;
  BID:for my $bid (keys %$bhash) {
    if ($bhash->{$bid}->{name} eq "Development Ministry") {
      $dlevel = $bhash->{$bid}->{level};
    }
    if ( defined($bhash->{$bid}->{pending_build})) {
      $bcnt++;
    }

    my $command_url = $bhash->{$bid}{url};

    my $command_type = Games::Lacuna::Client::Buildings::type_from_url($command_url);
    my @tags = Games::Lacuna::Client::Types::get_tags($command_type);

    my $sculpture = grep {/sculpture/} @tags;
    my $glyph     = grep {/glyph/}     @tags;
    my $command   = grep {/command/}   @tags;
    next if( $sculpture);
    next if( $glyph && ! $command);

    if ( $command_type eq 'GasGiantPlatform' && ( ! $opts{g} ) ) {
        next BID;
    }
    my $ref = $bhash->{$bid};
    $ref->{id} = $bid;
    push @sarr, $ref if ($ref->{level} < $opts{maxlevel} && $ref->{efficiency} == 100);
    @sarr = sort { $a->{level} <=> $b->{level} ||
                   $a->{x} <=> $b->{x} ||
                   $a->{y} <=> $b->{y} } @sarr;
  }

=pod
  if (scalar @sarr > ($dlevel + 1 - $bcnt)) {
    splice @sarr, ($dlevel + 1 - $bcnt);
  }
  if (scalar @sarr > ($opts{number})) {
    splice @sarr, ($opts{number} + 1 - $bcnt);
  }
=cut

  return (\@sarr);
}

sub sec2str {
  my ($sec) = @_;

  my $day = int($sec/(24 * 60 * 60));
  $sec -= $day * 24 * 60 * 60;
  my $hrs = int( $sec/(60*60));
  $sec -= $hrs * 60 * 60;
  my $min = int( $sec/60);
  $sec -= $min * 60;
  return sprintf "%04d:%02d:%02d:%02d", $day, $hrs, $min, $sec;
}

sub get_type_from_url {
  my ($url) = @_;

  my $type;
  eval {
    $type = Games::Lacuna::Client::Buildings::type_from_url($url);
  };
  if ($@) {
    print "Failed to get building type from URL '$url': $@";
    return 0;
  }
  return 0 if not defined $type;
  return $type;
}

sub usage {
    diag(<<END);
Usage: $0 [options]

This program upgrades spaceports on your planet. Faster than clicking each port.
It will upgrade in order of level up to maxlevel.

Options:
  --help             - This info.
  
  --gasgiant         - Upgrade Gas Giant Platforms
  --verbose          - Print out more information
  --config <file>    - Specify a GLC config file, normally lacuna.yml.
  --planet <name>    - Specify planet
  --dumpfile         - data dump for all the info we don't print
  --maxlevel         - do not upgrade if this level has been achieved.
  --number           - only upgrade at most this number of buildings
END
  exit 1;
}

sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub diag {
    my ($msg) = @_;
    print STDERR $msg;
}

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}
