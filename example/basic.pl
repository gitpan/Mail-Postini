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
my $smtporg = 'smtp.yourco.com';
my $smtpadmin = 'admin@yourco.com';
my $userorg = 'example.com';
my $userdomain = 'example.com';

my $mp = new Mail::Postini ( postini  => 'https://login.postini.com/exec/login',
                             username => shift @ARGV,
                             password => shift @ARGV,
                             secret   => shift @ARGV,
                             orgname  => shift @ARGV, );

print STDERR "Connecting...\n";
$mp->connect()
  or die "Errors: " . join(' ', $mp->errors) . "\n";

print STDERR "Creating email config ('$smtporg')\n";
my $mailorgid;
if( $mailorgid = $mp->get_orgid(name => $smtporg) ) {
    print STDERR "Email config already processed ($mailorgid).\n";
}
else {
    $mailorgid = $mp->create_organization( org             => $smtporg,
                                           name            => $smtporg,
                                           email_config    => 'yes',
                                           support_contact => $smtpadmin )
  or do {
      die "Could not create email organization: " . join(' ', $mp->errors);
  };
}

print STDERR "Setting up mail config mail server ($mailorgid)...\n";
$mp->set_org_mail_server( orgid   => $mailorgid,
                          server1 => $smtporg )
  or do {
      die "Could not set mail organization server: " . join(' ', $mp->errors);
  };

print STDERR "Fetching org mail server info...\n";
my %data = $mp->get_org_mail_server( orgid => $mailorgid );
print STDERR "Organization mail server data: $data{server1}\n";

print STDERR "Creating user org...\n";
my $userorgid;
if( $userorgid = $mp->get_orgid(name => $org) ) {
    print STDERR "User org ('$org') already exists ($userorgid).\n";
}

else {
    $userorgid = $mp->create_organization( org         => $org,
                                           parentorgid => $mailorgid,
                                           name        => "Scott Wiersdorf", )
      or do {
          die "Could not create user organization '$org': " . join(' ', $mp->errors);
      };
}

print STDERR "Adding domain to org ($userorgid)...\n";
$mp->add_domain( org    => $org,
                 domain => $userorg );

print STDERR "Looking up orgid from domain...\n";
my $org_from_domain = $mp->org_from_domain($userorg);
print STDERR "ORG from domain: '$org_from_domain'\n";

print STDERR "Adding user 1...\n";
make_user( $mp, user => "fluarty\@$userdomain", welcome => 1 );
sleep 2;

$mp->clear_errors;
print STDERR "Adding user 2...\n";
make_user( $mp, user => "basilisk\@$userdomain", 'welcome' => 1 );
sleep 2;

print STDERR "Fetching user...\n";
%data = $mp->get_user_data("fluarty\@$userdomain")
  or do {
      sleep 1;
      %data = $mp->get_user_data("fluarty\@$userdomain");
  };
print Dumper(\%data);

print STDERR "Listing users...\n";
my $users = $mp->list_users( domain => $userdomain );
print STDERR "I GOTS THIS MANY USERS for $userdomain: " . scalar(keys %$users) . "\n";

print STDERR "Removing users...\n";
sleep 2;
$mp->delete_user( "fluarty\@$userdomain" );
$mp->delete_user( "basilisk\@$userdomain" );
sleep 1;

print STDERR "Deleting domain...\n";
$mp->delete_domain( domain => $userdomain );
sleep 1;

print STDERR "Deleting user organization...\n";
$mp->delete_organization( org => $org );

print STDERR "Deleting email organization...\n";
$mp->delete_organization( orgid => $mailorgid );

exit;

## a more robust add_user (Postini doesn't always work over LWP)
sub make_user {
    my $mp = shift;
    my %args = @_;

    my $tries = 3;
  ADD_USER: {
        last ADD_USER if $tries < 1;
        unless( $mp->add_user( $args{user}, welcome => $args{welcome} ) ) {
            warn "Could not add user: " . join(' ', $mp->errors) . "\n";
            $tries--;
            warn "Trying '$tries' times to add user...\n";
            sleep 2;
            redo ADD_USER;
        }
    }
}
