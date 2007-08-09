#!/usr/bin/perl
use strict;
use warnings;

use blib;
use Mail::Postini ();
use Data::Dumper;

## usage: example.pl postini@yourco.com somepassword "your ezcommand passphrase" "Your Postini Org"

## this example will create a new sub organization of "Your Postini
## Org" (which must already exist), add to it a domain 'example.com'
## and to that, an email address 'fluarty@example.com'

my $org = 'My Sub-Org';

my $mp = new Mail::Postini ( postini  => 'https://login.postini.com/exec/login',
                             username => shift @ARGV,
                             password => shift @ARGV,
                             secret   => shift @ARGV,
                             orgname  => shift @ARGV, );

print STDERR "Connecting...\n";
$mp->connect()
  or die "Errors: " . join(' ', $mp->errors) . "\n";

print STDERR "Creating org...\n";
my $neworg = $mp->create_organization( org => $org )
  or do {
      warn "Could not get an organization number (maybe already exists?)\n";
  };

$neworg ||= '';

print STDERR "New org number: $neworg\n" if $neworg;

print STDERR "Trying to fetch org number...\n";
my $orgid = $mp->get_orgid( name => $org );

print STDERR "Org id: $orgid; New org id: $neworg\n";

print STDERR "Adding domain to org...\n";
$mp->add_domain( org    => $org,
                 domain => 'example.com' );

print STDERR "Adding user...\n";
$mp->add_user( 'fluarty@example.com', 'welcome' => 1 );
sleep 2;

print STDERR "Fetching user...\n";
my %data = $mp->get_user_data('fluarty@example.com');
print Dumper(\%data);

print STDERR "Again...\n";
my $data = $mp->list_users( domain => 'example.com' );
print Dumper($data);

print STDERR "Removing user...\n";
$mp->delete_user( 'fluarty@example.com' );
sleep 1;

print STDERR "Deleting domain...\n";
$mp->delete_domain( domain => 'example.com' );
sleep 1;

print STDERR "Deleting organization...\n";
$mp->delete_organization( org => $org );
