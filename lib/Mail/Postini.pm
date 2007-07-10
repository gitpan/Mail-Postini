package Mail::Postini;

use 5.008001;
use strict;
use warnings;

our $VERSION = '0.07';
our $CVSID   = '$Id: Postini.pm,v 1.2 2007/07/10 22:25:20 scott Exp $';
our $Debug   = 0;

use LWP::UserAgent ();
use URI::Escape 'uri_escape';
use Digest::SHA1 'sha1_base64';
use HTML::Form ();
use Carp 'carp';
use Data::Dumper 'Dumper';

## NOTE: This is an inside-out object; remove members in
## NOTE: the DESTROY() sub if you add additional members.

my %postini   = ();
my %app_serv  = ();
my %username  = ();
my %password  = ();
my %secret    = ();
my %orgid     = ();
my %orgname   = ();
my %ua        = ();
my %agent     = ();
my %errors    = ();
my %err_pages = ();

sub new {
    my $class = shift;
    my %args  = @_;

    my $self = bless \(my $ref), $class;

    $args{postini}  ||= '';
    $args{username} ||= '';
    $args{password} ||= '';
    $args{secret}   ||= '';
    $args{orgid}    ||= '';
    $args{orgname}  ||= '';
    $args{agent}    ||= 'perl/Mail-Postini $VERSION';

    $postini   {$self} = $args{postini};
    $app_serv  {$self} = '';
    $username  {$self} = $args{username};
    $password  {$self} = $args{password};
    $secret    {$self} = $args{secret};
    $orgid     {$self} = $args{orgid};
    $orgname   {$self} = $args{orgname};
    $agent     {$self} = $args{agent};
    $errors    {$self} = [];
    $err_pages {$self} = [];

    return $self;
}

## this gets us a cookie and gives us some state when we need it
sub connect {
    my $self = shift;
    my %args = @_;

    exists $args{postini}  and $postini  {$self} = $args{postini};
    exists $args{username} and $username {$self} = $args{username};
    exists $args{password} and $password {$self} = $args{password};
    exists $args{secret}   and $secret   {$self} = $args{secret};
    exists $args{orgid}    and $orgid    {$self} = $args{orgid};
    exists $args{orgname}  and $orgname  {$self} = $args{orgname};
    exists $args{agent}    and $agent    {$self} = $args{agent};

    $ua{$self} = LWP::UserAgent->new;
    $ua{$self}->agent($agent{$self});
    $ua{$self}->cookie_jar({});

    my $uname = uri_escape($username{$self});
    my $upass = uri_escape($password{$self});

    ## authenticate
    my $req = HTTP::Request->new( POST => $postini{$self} );
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "email=$uname&pword=$upass&action=login" );
    my $res = $ua{$self}->request($req);
    unless( $res->code == 302 ) {
	$self->errors("Failure: " . $res->code . ': ' . $res->message);
	$self->err_pages($res);
	return;
    }

    ## get landing page
    $req = HTTP::Request->new( GET => $res->header('location') );
    $res = $ua{$self}->request($req);

    unless( $res->code == 200 ) {
	$self->errors("Failure: " . $res->code . ': ' . $res->message);
	$self->err_pages($res);
	return;
    }

    ## get system admin page
    my ($sa_page) = $res->content =~ m{<a href="(.+?)".*>System Administration</a>};
    $req = HTTP::Request->new( GET => $sa_page );
    $res = $ua{$self}->request($req);

    ($app_serv{$self}) = $sa_page =~ m!^(https?://[^/]+)/!;

    my($orgid) = $res->content =~ /^\s*<option value="(\d+)"(?: selected)?>$orgname{$self}$/im;
    ($orgid{$self}) ||= $orgid;

    return 1;
}

sub create_organization {
    my $self = shift;
    my %args = @_;

    my $org = $args{org};
    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_orgs?targetorgid=$orgid{$self}! );
    my $res = $ua{$self}->request($req);

    my $form = $self->_get_form($res, qr(/exec/admin_orgs\?targetorgid=$orgid{$self}$),
                                { type  => 'submit',
                                  value => 'Add',
                                  name  => '', } )
      or do {
          carp "Form error: " . join(', ', $self->errors());
          return;
      };

    $form->value( "setconf-neworg" => $org );
    $form->value( "setconf-parent" => $orgname{$self} );
    $form->value( "action"         => "addOrg" );
    $res = $ua{$self}->request( $form->click() );

    unless( $res->code == 302 ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    my($new_org) = $res->content =~ /\btargetorgid=(\d+)"/;

    return ( $new_org ? $new_org : undef );
}

sub delete_organization {
    my $self = shift;
    my %args = @_;
    my $org = $args{org}
      or do {
          warn "Organization name required.\n";
          return;
      };

    my $req;
    my $res;

    my $orgid = $self->get_orgid( name => $org );

    $req = HTTP::Request->new( POST => qq!$app_serv{$self}/exec/admin_orgs?targetorgid=$orgid! );
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "confirm=Confirm&action=deleteOrg" );
    $res = $ua{$self}->request($req);

    unless( $res->code == 302 ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub get_user_data {
    my $self = shift;
    my $user = shift;

    ## get the users list w/ settings
    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_listusers_download?aliases=0&type_of_user=all&pagesize=25&type_of_encrypted_user=ext_encrypt_on&sortkeys=address%3Aa&pagenum=1&targetorgid=$orgid{$self}&childorgs=1&type=usersets! );
    my $res = $ua{$self}->request($req);

    my @keys  = ();
    my %users = ();

  LINES: for my $line ( split(/\n/, $res->content) ) {

        ## find the keys
        if( $line =~ /^\#/ ) {
            next unless $line =~ /address/;
            next if @keys;

            $line =~ s/^#\s*//;
            @keys = split(/,/, $line);
            next;
        }

        next LINES unless @keys;

        if( $user ) {
            next LINES unless $line =~/^$user,/;
        }

        my @fields = ();
        my $state = 0;
        CHUNK: for my $chunk ( split(/,/, $line) ) {

            if( $state == 1 ) {
                if( $chunk =~ s/"$// ) {
                    $state = 0;
                }

                $fields[$#fields] .= ',' . $chunk;
                next CHUNK;
            }

            if( $chunk =~ s/^"// ) {
                $state = 1;
            }

            push @fields, $chunk;
        }


        my %acct = ();
        @acct{@keys} = @fields;
        $users{$acct{$keys[0]}} = \%acct;
    }

    return %users;
}

sub get_orgid {
    my $self = shift;
    my %args = @_;

    if( $args{name} eq $orgname{$self} ) {
        return $orgid{$self};
    }

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_list?type=orgs! );
    my $res = $ua{$self}->request($req);

    my($orgid) = $res->content =~ /^\s*<option value="(\d+)"(?: selected)?>$args{name}$/im;

    return( $orgid ? $orgid : undef );
}

sub add_domain {
    my $self = shift;
    my %args = @_;

    my $orgid   = $self->get_orgid( name => $args{org} );
    my $orgname = $args{org};
    my $domain  = $args{domain};

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_domains?action=display_Add&targetorgid=$orgid! );
    my $res = $ua{$self}->request($req);

    my $form = $self->_get_form($res, qr(/exec/admin_domains))
      or do {
          warn "Could not find form.\n";
          return;
      };

    $form->value( "setconf-targetorg"  => $orgname );
    $form->value( "setconf-domainname" => $domain );
    $form->value( "action"             => "addDomain" );
    $res = $ua{$self}->request( $form->click('save') );

    unless( $res->code == 302 ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub delete_domain {
    my $self = shift;
    my %args = @_;

    my $req = HTTP::Request->new( POST => qq!$app_serv{$self}/exec/admin_domains! );
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "setconf-domainname=$args{domain}&action=deleteDomain&delete=Delete" );

    my $res = $ua{$self}->request($req);

    unless( $res->code == 302 ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub add_user {
    my $self = shift;
    return $self->_do_command('adduser', @_);
}

sub delete_user {
    my $self = shift;
    return $self->_do_command('deleteuser', @_);
}

sub _do_command {
    my $self = shift;
    my $cmd  = shift;
    my $args = shift;

    my $radd = chr(rand(26) + 0x41) . chr(rand(26) + 0x41) . 
      chr(rand(26) + 0x41) . chr(rand(26) + 0x41) . $username{$self};

    my $sig = sha1_base64( $radd . $secret{$self} ) . $radd;

    $args = uri_escape($args);

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/remotecmd?auth=${sig}&cmd=${cmd}%20${args}! );
    my $res = LWP::UserAgent->new->request($req);

    unless( $res->content =~ /^1\s/ ) {
        $self->errors("Failure: " . $res->content);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub errors {
    my $self = shift;

    if( @_ ) {
	push @{ $errors{$self} }, @_;
	return;
    }

    return @{ $errors{$self} };
}

sub clear_errors {
    my $self = shift;
    $errors{$self} = [];
}

sub err_pages {
    my $self = shift;

    if( @_ ) {
	push @{ $err_pages{$self} }, @_;
	return;
    }

    return @{ $err_pages{$self} };
}

sub clear_err_pages {
    my $self = shift;
    $err_pages{$self} = [];
}

sub DESTROY {
    my $self = $_[0];

    delete $postini   {$self};
    delete $app_serv  {$self};
    delete $username  {$self};
    delete $password  {$self};
    delete $secret    {$self};
    delete $orgid     {$self};
    delete $orgname   {$self};
    delete $ua        {$self};
    delete $agent     {$self};
    delete $errors    {$self};
    delete $err_pages {$self};

    my $super = $self->can("SUPER::DESTROY");
    goto &$super if $super;
}

sub _get_form {
    my $self   = shift;
    my $res    = shift;
    my $action = shift;
    my $inputs = shift;    ## input values to find

    my @forms = HTML::Form->parse( $res->content, $res->base );
    my $form;
  FORMS: for my $frm ( @forms ) {
        print STDERR "Comparing form action...\n" if $Debug;
	unless( $frm->action =~ $action ) {
            print STDERR "Skipping (" . $frm->action . " !~ $action)\n" if $Debug;
            next FORMS;
        }

        ## we have more criteria to weed out the form we want
        if( keys %$inputs ) {
            my $input_match;

          FORM_INPUT: for my $finput ( $frm->inputs ) {
                print STDERR Dumper($finput) if $Debug;
                if( exists $inputs->{type} ) {
                    print STDERR "Comparing type ($inputs->{type} <=?> " . $finput->type . ")\n" if $Debug;
                    next FORM_INPUT unless $finput->type eq $inputs->{type};
                }

                if( exists $inputs->{value} ) {
                    print STDERR "Comparing value ($inputs->{value} <=?> " . $finput->value . ")\n" if $Debug;
                    next FORM_INPUT unless $finput->value eq $inputs->{value};
                }

                if( exists $inputs->{name} ) {
                    no warnings;
                    print STDERR "Comparing name ($inputs->{name} <=?> " . $finput->name . ")\n" if $Debug;
                    next FORM_INPUT unless $finput->name eq $inputs->{name};
                }

                ## match
                print STDERR "Input field match!\n" if $Debug;
                $input_match = 1;
                last FORM_INPUT if $input_match;
            }
        }

	$form = $frm;
	last
    }

    unless( $form ) {
	$self->errors( "Could not find form with action '$action'. Interface change?" );
        return;
    }
    print STDERR "Got a form now...\n" if $Debug;

    return $form;
}

sub _do_redirect {
    my $self = shift;
    my $page = shift;

    my $req = HTTP::Request->new(GET => $page);
    my $res = $ua{$self}->request($req);
    unless( $res->code == 200 ) {
	$self->errors( "Failure: " . $res->code . ": " . $res->message );
	return;
    }

    return $res;
}

1;
__END__

=head1 NAME

Mail::Postini - Perl extension for talking to Postini

=head1 SYNOPSIS

  use Mail::Postini;
  my $mp = new Mail::Postini ( postini  => 'https://login.postini.com/exec/login',
                               username => 'some@one.tld',
                               password => '3dk2j3jd8fk3kfuasdf',
                               secret   => 'this is our secret postini key',
                               orgname  => 'Our Customers' );

  $mp->connect()
    or die "Errors: " . join(' ', $mp->errors) . "\n";

=head1 DESCRIPTION

B<Mail::Postini> performs some web requests and some EZConnect API
calls to a Postini mail server. It is meant to give a programmatic
interface to many of the common tasks associated with adding,
maintaining, and removing mail users from a Postini organization.

Nota bene: the web interface for Postini can change at any time,
thereby breaking this module. We take some precautions against this,
but can only do so much with web interfaces that aren't guaranteed
like an API. Proceed with caution.

=head2 new ( %args )

Constructor.

Example:

  my $mp = new Mail::Postini ( postini  => 'https://login.postini.com/exec/login',
                               username => 'some@one.tld',
                               password => '3dk2j3jd8fk3kfuasdf',
                               secret   => 'this is our secret postini key',
                               orgname  => 'Our Customers' );

=head2 connect ()

Makes a connection to the Postini mail server and initializes the
object. If you're only using the EZCommands, you don't need to do this
method (which can be slow).

Example:

  $mp->connect() or die join(' ', $mp->errors);

=head2 create_organization ( $organization_name )

Creates a new organization as a sub-org of the organization specified
in the constructor by I<orgname>.

Example:

  $mp->create_organization( org => 'New Sub-Org' );

=head2 delete_organization ( $organization_name )

Deletes an organization. All domains must be deleted from the
organization first.

Example:

  $mp->delete_organization( org => 'Old Sub-Org' );

=head2 get_user_data ( $username )

Retrieves the current settings for a user in the form of a hash.

Example:

  my %data = $mp->get_user_data('joe@domain.tld');

=head2 get_orgid ( name => $organization_name )

Returns the numerical Postini organization id (used internally to
identify a Postini organization or sub-organization).

Example:

  my $orgid = $mp->get_orgid( name => 'My Org' );

=head2 add_domain ( org => $org, domain => $domain )

Adds a domain to an organization.

Example:

  $mp->add_domain( org => 'My Org', domain => 'somedomain.tld' );

=head2 delete_domain ( domain => $domain )

Deletes a domain from a Postini configuration. All users must be
deleted from the domain first.

  $mp->delete_domain( domain => 'somedomain.tld' );

=head2 add_user ( $username )

Adds an email address to a Postini domain. When the user is added,
Postini will filter mail for it. The domain must be added to an
organization prior to you adding the user.

Example:

  $mp->add_user( 'joe@somedomain.tld' );

=head2 delete_user ( $username )

Deletes an email address from a Postini configuration.

Example:

  $mp->delete_user( 'joe@somedomain.tld' );

=head2 errors ()

Returns a list of any errors accumulated since the last time errors
were cleared.

Example:

  print "Errors: " . join(' ', $mp->errors) . "\n";

=head2 clear_errors ()

Clears the object's internal error list.

=head2 err_pages ()

Returns a list of HTTP::Response objects which you can use to
troubleshoot connection or parsing problems.

  my $res = ($mp->err_pages)[0];
  print $res->content;

=head2 clear_err_pages ()

Clears the object's internal error page list.

=head1 EXAMPLE

  my $mp = new Mail::Postini ( postini  => 'https://login.postini.com/exec/login',
                               username => 'joe@domain.tld',
                               password => 'mypasswordrocks!',
                               secret   => 'My EZCommand Password',
                               orgname  => 'My Customers' );

  $mp->connect()
    or die "Couldn't connect to server: " . join(' ', $mp->errors);

  ## 'Customer Accounts' is a sub-org of 'My Customers' (which is a
  ## template organization)
  my $organization = 'Customer Accounts';

  ## add the domain to 'Customer Accounts' organization
  $mp->add_domain( org    => $organization,
                   domain => 'newdomain.tld' );

  ## add a new user to this domain
  $mp->add_user( 'gordon@newdomain.tld' );

  ## get settings for this user
  my %settings = $mp->get_user_data( 'gordon@newdomain.tld' );
  print Data::Dumper::Dumper(\%settings);

=head1 SEE ALSO

B<Mail::Foundry> (some page parsing routines were done here first).
B<HTTP::Response>

=head1 AUTHOR

Scott Wiersdorf, E<lt>scott@perlcode.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Scott Wiersdorf

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.6 or,
at your option, any later version of Perl 5 you may have available.


=cut
