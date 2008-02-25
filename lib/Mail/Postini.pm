package Mail::Postini;

use 5.008001;
use strict;
use warnings;

our $VERSION = '0.17';
our $CVSID   = '$Id: Postini.pm,v 1.12 2008/02/25 18:26:49 scott Exp $';
our $Debug   = 0;
our $Trace   = 0;

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

    $orgid{$self} ||= $self->get_orgid( name => $orgname{$self} );

    return 1;
}

sub create_organization {
    my $self = shift;
    my %args = @_;

    my $parentorgid;
    unless( $parentorgid = $args{parentorgid} ) {
        $parentorgid = $self->get_orgid( name => $args{parentorg} )
          if $args{parentorg};
        $parentorgid ||= $orgid{$self};  ## top level org
    }
    print STDERR "Parent orgid: $parentorgid\n" if $Debug;

    my $org = $args{org};
    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_orgs?targetorgid=$parentorgid! );
    my $res = $ua{$self}->request($req);

    print STDERR "call _get_form in create_organization()\n" if $Trace;
    my $form = $self->_get_form($res, qr(/exec/admin_orgs\?targetorgid=${parentorgid}$),
                                { type  => 'submit',
                                  value => 'Add',
                                  name  => '', } )
      or do {
          carp "Form error: " . join(', ', $self->errors());
          return;
      };

    print STDERR "setting form variables\n" if $Trace;
    $form->value( "setconf-neworg" => $org );
    $form->value( "setconf-parent" => $parentorgid );
    $form->value( "action" => "addOrg" );
    $res = $ua{$self}->request( $form->click() );

    unless( $res->is_redirect ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    print STDERR "Form submission ok\n" if $Trace;
    my($new_org) = $res->content =~ /\btargetorgid=(\d+)"/
      or return;

    ## https://ac-s7.postini.com/exec/admin_orgs?targetorgid=100059067&action=display_GeneralSettings
    $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_orgs?targetorgid=${new_org}&action=display_GeneralSettings! );
    $res = $ua{$self}->request($req);

    ## this trick might be useful sometime in the future. It certainly
    ## makes the redirect more change-tolerant
#    $res = $self->_do_redirect($app_serv{$self} . $res->header('location'));

    print STDERR "call _get_form to set org details\n" if $Trace;
    my $setform = $self->_get_form($res, qr(\badmin_orgs\b), { type  => 'text',
                                                               name  => 'setconf-name', })
      or do {
          carp "Form error: " . join(', ', $self->errors());
          return;
      };

    $setform->value('setconf-name'            => $args{name})            if $args{name};
    $setform->value('setconf-is_email_config' => $args{email_config})    if $args{email_config};
    $setform->value('setconf-support_contact' => $args{support_contact}) if $args{support_contact};
    $setform->value('setconf-api_secret'      => $args{api_secret})      if $args{api_secret};

    $res = $ua{$self}->request( $setform->click() );

    unless( $res->is_redirect ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    print STDERR "Successful organization creation ($new_org)\n" if $Trace;
    return ( $new_org ? $new_org : undef );
}

sub list_organizations {
    my $self = shift;
    my %args = @_;

    my $orgid = $args{orgid} || $self->get_orgid( name => $orgname{$self} );

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_listorgs_download?sortkeys=orgtag%3Ah&type_of_user=all&childorgs=1&type_of_encrypted_user=ext_encrypt_any&aliases=0&targetorgid=${orgid}&type=orgsets! );
    my $res = $ua{$self}->request($req);

    my @keys = ();
    my %orgs = ();

  LINES: for my $line ( split(/\n/, $res->content) ) {

        ## find the keys
        if( $line =~ /^\#/ ) {
            next unless $line =~ /\borgname\b/;
            next if @keys;

            $line =~ s/^#\s*//;
            @keys = split(/,/, $line);
            next;
        }

        next LINES unless @keys;

        ## FIXME: here skip all orgs except the one we're looking for...
        ## next unless $line =~ /^$args{orgname}/;  ## or something like that.

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
        $orgs{$acct{$keys[0]}} = \%acct;
    }

    return \%orgs;

}

sub set_org_data {
    my $self = shift;
    my %args = @_;

    unless( $args{orgid} ) {
        unless( $args{org} ) {
            $self->errors("Failure: orgid or og parameter required for set_org_data()");
            return;
        }

        $args{orgid} = $self->get_orgid( name => $args{orgid})
          or do {
              $self->errors("Failure: Could not get orgid for '$args{org}' (misspelled org name, or Postini down?)");
              return;
          };
    }

    my $orgid = $args{orgid};

    if( $args{section} eq 'GeneralSettings' ) {
        my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_orgs?targetorgid=${orgid}&action=display_GeneralSettings! );
        my $res = $ua{$self}->request($req);

        my $form = $self->_get_form($res, qr(admin_orgs\?targetorgid=${orgid}), 
                                    { type => 'text', name => 'setconf-name' } )
          or do {
              carp "Form error: " . join(", ", $self->errors);
              return;
          };

        $form->value( action => "modifyGeneralSettings" );

        $form->value( "setconf-name"            => $args{name} )            if $args{name};
        $form->value( "setconf-orgtag"          => $args{orgtag} )          if $args{orgtag};
        $form->value( "setconf-parent"          => $args{parent} )          if $args{parent};
        $form->value( "setconf-support_contact" => $args{support_contact} ) if $args{support_contact};
        $form->value( "setconf-api_secret"      => $args{api_secret} )      if $args{api_secret};
        $form->value( "setconf-tight_postini"   => $args{tight_postini} )   if $args{tight_postini};
        $form->value( "setconf-default_user"    => $args{default_user} )    if $args{default_user};
        $form->value( "setconf-smartcreate"     => $args{smartcreate} )     if $args{smartcreate};
        $form->value( "setconf-quar_links"      => $args{quar_links} )      if $args{quar_links};
        $form->value( "setconf-timezone"        => $args{timezone} )        if $args{timezone};
        $form->value( "lang"                    => $args{lang} )            if $args{lang};
        $form->value( "encoding"                => $args{encoding} )        if $args{encoding};
        $form->value( "cascade"                 => $args{cascade} )         if $args{cascade};

        $res = $ua{$self}->request( $form->click('save') );

        unless( $res->is_redirect ) {
            $self->errors("Failure: " . $res->code . ": " . $res->message);
            $self->err_pages($res);
            return;
        }
    }

    return 1;
}

sub set_org_mail_server {
    my $self = shift;
    my %args = @_;

    unless( $args{orgid} ) {
        unless( $args{org} ) {
            $self->errors("Failure: orgid or org parameter required for set_org_mail_server()");
            return;
        }

        $args{orgid} = $self->get_orgid( name => $args{org} )
          or do {
              $self->errors("Failure: Could not get orgid for '$args{org}' (misspelled org name, or Postini down?)");
              return;
          };
    }

    my $orgid = $args{orgid};

    ## param check
    unless( $args{server1} ) {
        $self->errors("Failure: server1 parameter required for set_org_mail_server()");
        return;
    }
    $args{weight1} ||= 100;
    $args{maxcon1} ||= '';

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/delivmgr?targetorgid=${orgid}&action=display_Edit!);
    my $res = $ua{$self}->request($req);

    my $form = $self->_get_form($res, qr(\b/exec/delivmgr\b))
      or do {
          carp "Form error: " . join(", ", $self->errors());
          return;
      };

    $form->value("action"       => 'modifyDeliv');
    $form->value("targetorgid"  => $orgid);
    $form->value("mailhost-0|0" => $args{server1});
    $form->value("weight-0|0"   => $args{weight1});
    $form->value("maxcon-0|0"   => $args{maxcon1});

    if( $args{server2} ) {
        $args{weight2} ||= 50;
        $args{maxcon2} ||= '';

        $form->value("mailhost-0|1" => $args{server2});
        $form->value("weight-0|1"   => $args{weight2});
        $form->value("maxcon-0|1"   => $args{maxcon2});
    }

    if( $args{failover1} ) {
        $args{fo_weight1} ||= 50;
        $args{fo_maxcon1} ||= '';

        $form->value("mailhost-1|0" => $args{failover1});
        $form->value("weight-1|0"   => $args{fo_weight1});
        $form->value("maxcon-1|0"   => $args{fo_maxcon1});
    }

    if( $args{failover2} ) {
        $args{fo_weight2} ||= 25;
        $args{fo_maxcon2} ||= '';

        $form->value("mailhost-1|1" => $args{failover2});
        $form->value("weight-1|1"   => $args{fo_weight2});
        $form->value("maxcon-1|1"   => $args{fo_maxcon2});
    }

    if( $args{failover3} ) {
        $args{fo_weight3} ||= 25;
        $args{fo_maxcon3} ||= '';

        $form->value("mailhost-1|2" => $args{failover3});
        $form->value("weight-1|2"   => $args{fo_weight3});
        $form->value("maxcon-1|2"   => $args{fo_maxcon3});
    }

    $form->value("overflow" => 1) if $args{overflow};

    $res = $ua{$self}->request( $form->click() );

    unless( $res->is_redirect ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub get_org_mail_server {
    my $self = shift;
    my %args = @_;

    unless( $args{orgid} ) {
        unless( $args{org} ) {
            $self->errors("Failure: orgid or org parameter required for get_org_mail_server()");
            return;
        }

        $args{orgid} = $self->get_orgid( name => $args{org} )
          or do {
              $self->errors("Failure: Could not get orgid for '$args{org}' (misspelled org name or Postini down?)");
              return;
          };
    }

    my $orgid = $args{orgid};
    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/delivmgr?targetorgid=$orgid&action=display_Edit! );
    my $res = $ua{$self}->request($req);

    my $form = $self->_get_form($res, qr(\bdelivmgr\b), { type => 'hidden',
                                                          name => 'action',
                                                          value => 'modifyDeliv' })
      or do {
          warn "Could not find form.\n";
          $self->err_pages($res);
          return;
      };

    my %data = ();
    $data{server1} = $form->value('mailhost-0|0');
    $data{weight1} = $form->value('weight-0|0');
    $data{maxcon1} = $form->value('maxcon-0|0');

    $data{server2} = $form->value('mailhost-0|1');
    $data{weight2} = $form->value('weight-0|1');
    $data{maxcon2} = $form->value('maxcon-0|1');

    $data{failover1}  = $form->value('mailhost-1;0');
    $data{fo_weight1} = $form->value('weight-1;0');
    $data{fo_maxcon1} = $form->value('maxcon-1;0');

    $data{failover2}  = $form->value('mailhost-1;1');
    $data{fo_weight2} = $form->value('weight-1;1');
    $data{fo_maxcon2} = $form->value('maxcon-1;1');

    $data{failover3}  = $form->value('mailhost-1;2');
    $data{fo_weight3} = $form->value('weight-1;2');
    $data{fo_maxcon3} = $form->value('maxcon-1;2');

    return %data;
}

sub delete_organization {
    my $self = shift;
    my %args = @_;

    my $req;
    my $res;

    unless( $args{orgid} ) {
        unless( $args{org} ) {
            $self->errors("orgid or org parameter required for delete_organization()");
            return;
        }

        $args{orgid} = $self->get_orgid( name => $args{org} )
          or do {
              $self->errors("Could not fetch orgid from '$args{org}'");
              return;
          };
    }

    $req = HTTP::Request->new( POST => qq!$app_serv{$self}/exec/admin_orgs?targetorgid=$args{orgid}! );
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "confirm=Confirm&action=deleteOrg" );
    $res = $ua{$self}->request($req);

    unless( $res->is_redirect ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub get_user_data {
    my $self = shift;
    my $user = shift;

    my($domain) = $user =~ /\@(.+)$/
      if $user;

    my %args = ();
    $args{user}   = $user if $user;
    $args{domain} = $domain if $domain;
    my $users = $self->list_users( %args );
    return ($users ? %$users : ());
}

sub get_orgid {
    my $self = shift;
    my %args = @_;

    if( $args{name} eq $orgname{$self} ) {
        return $orgid{$self} if $orgid{$self};  ## for bootstrapping
    }

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_list?type=orgs&orgtagqs=$args{name}! );
    my $res = $ua{$self}->request($req);

    my ($chunk) = $res->content =~ m#<!-- START ORG ROW -->\n(.+)\n<!-- END ORG ROW -->#s;
    return unless $chunk;

    my ($orgid) = $chunk =~ m!<a href="/exec/admin_orgs\?.+?&targetorgid=(\d+)"><b>$args{name}</b></a>!;
    return( $orgid ? $orgid : undef );
}

sub add_domain {
    my $self = shift;
    my %args = @_;

    unless( $args{orgid} ) {
        unless( $args{org} ) {
            $self->errors("orgid or org parameter required for delete_organization()");
            return;
        }

        $args{orgid} = $self->get_orgid( name => $args{org} )
          or do {
              $self->errors("Could not fetch orgid from '$args{org}'");
              return;
          };
    }

    my $orgname = $args{org};
    my $domain  = $args{domain};

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_domains?action=display_Add&targetorgid=$args{orgid}! );
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

sub org_from_domain {
    my $self = shift;
    my $domain = shift;

    my $qs = qq!$app_serv{$self}/exec/admin_list?type=domains&childorgs=0&domainqs=${domain}&childorgs=1&Search=Search!;
    my $req = HTTP::Request->new( GET => $qs );
    my $res = $ua{$self}->request($req);

    my ($chunk) = $res->content =~ m#<!-- START DOMAIN ROW -->\n(.+)\n<!-- END DOMAIN ROW -->#s;
    return unless $chunk;

    my ($orgid) = $chunk =~ m!$domain.+?</td>\n<td\b.+/admin_orgs\?action=display_Overview&targetorgid=(\d+)!;
    return unless $orgid;

    return $orgid;
}

sub list_users {
    my $self = shift;
    my %args = @_;

  GET_ORGID: {
        last GET_ORGID if $args{orgid};

        ## no org given...
        unless( $args{org} ) {

            ## but we have a domain we can search on
            if( $args{domain} ) {
                if( $args{orgid} = $self->org_from_domain($args{domain}) ) {
                    last GET_ORGID;
                }

                ## bite the bullet and suck up the memory...
                $args{orgid} = $orgid{$self};
                last GET_ORGID;
            }

            $self->errors("Failure: domain, orgid, or org parameter required for list_users()");
            return;
        }

        last GET_ORGID if $args{orgid} = $self->get_orgid( name => $args{org} );

        $self->errors("Failure: Could not get orgid for '$args{org}' (misspelled org name or Postini down?)");
        return;
    }

    my $qs = qq!$app_serv{$self}/exec/admin_listusers_download?aliases=0&type_of_user=all&pagesize=25&type_of_encrypted_user=ext_encrypt_on&sortkeys=address%3Aa&pagenum=1&targetorgid=$args{orgid}&childorgs=1&type=usersets!;
    $qs .= "&addressqs=$args{domain}%24" if $args{domain};

    my $req = HTTP::Request->new( GET => $qs );
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

        if( $args{user} ) {
            next LINES unless $line =~/^$args{user},/;
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

    return \%users;
}

## this requires much more parsing than list_users
sub list_aliases {
    my $self = shift;
    my %args = @_;

  GET_ORGID: {
        last GET_ORGID if $args{orgid};

        ## no org given...
        unless( $args{org} ) {

            ## but we have a domain we can search on
            if( $args{domain} ) {
                if( $args{orgid} = $self->org_from_domain($args{domain}) ) {
                    last GET_ORGID;
                }

                ## bite the bullet and suck up the memory...
                $args{orgid} = $orgid{$self};
                last GET_ORGID;
            }

            $self->errors("Failure: domain, orgid, or org parameter required for list_users()");
            return;
        }

        last GET_ORGID if $args{orgid} = $self->get_orgid( name => $args{org} );

        $self->errors("Failure: Could not get orgid for '$args{org}' (misspelled org name or Postini down?)");
        return;
    }

    my $qs = qq!$app_serv{$self}/exec/admin_list?type_of_user=all&type=usersets&childorgs=0&addressqs=&orgtagqs=&primaryqs=.*&aliases=1&childorgs=1&Search=Search!;
    $qs .= "&addressqs=$args{domain}%24" if $args{domain};

    my $req = HTTP::Request->new( GET => $qs );
    my $res = $ua{$self}->request($req);

    my %users = ();

    my ($chunk) = $res->content =~ m#<!-- START USER SETTINGS LISTING -->\n(.+)\n<!-- END USER SETTINGS LISTING -->#s;
    return unless $chunk;

    for my $record ( split(/<!-- START USER SETTINGS ROW -->/, $chunk ) ) {
        next if $record =~ /alt="Bulk"/;

        my($alias, $user) = $record =~ m!<tr.+?><b>([^<]+)</b></a>.*?</td>.*?</td>.*?<a href="/exec/admin_users.+?">([^<]+)</a>!s
          or next;

        unless( $users{$user} ) {
            $users{$user} = [];
        }

        push @{$users{$user}}, $alias;
    }

    return \%users;
}

sub add_user {
    my $self = shift;
    return $self->_do_command('adduser', @_);
}

sub delete_user {
    my $self = shift;
    return $self->_do_command('deleteuser', @_);
}

sub reset_user_password {
    my $self = shift;
    my %args = @_;

    unless( $args{user} ) {
        $self->errors("user parameter required for reset_user_password()");
        return;
    }

    my %data = $self->get_user_data( $args{user} )
      or do {
          $self->errors("Error fetching user list from '$args{user}'");
          return;
      };

    my $user_id = $data{$args{user}}->{user_id}
      or do {
          $self->errors("Could not fetch user_id from '$args{user}'");
          return;
      };

    my $req = HTTP::Request->new( GET => qq!$app_serv{$self}/exec/admin_users?targetorgid=&targetuserid=$user_id&action=display_Password! );
    my $res = $ua{$self}->request($req);

    my $form = $self->_get_form($res, qr(\badmin_users\b))
      or do {
          carp "Form error: " . join(', ', $self->errors());
          return;
      };

    if( $args{password} ) {
        $form->value( resetchoice => 2 );
        $form->value( notify  => 1 ) if $args{notify};
    }

    else {
        $form->value( resetchoice => 1 );
    }
    $form->value( action => 'modifyPassword' );

    $res = $ua{$self}->request( $form->click('save') );

    unless( $res->code == 302 ) {
        $self->errors("Failure: " . $res->code . ": " . $res->message);
        $self->err_pages($res);
        return;
    }

    return 1;
}

sub _do_command {
    my $self = shift;
    my $cmd  = shift;
    my $addr = shift;
    my %args = @_;

    my $radd = chr(rand(26) + 0x41) . chr(rand(26) + 0x41) . 
      chr(rand(26) + 0x41) . chr(rand(26) + 0x41) . $username{$self};

    my $sig = sha1_base64( $radd . $secret{$self} ) . $radd;

    $addr = uri_escape($addr);

    my @args = ();
    for my $key ( keys %args ) {
        push @args, uri_escape($key) . '=' . uri_escape($args{$key});
    }
    my $args = join('&', @args) || '';

    my $auth = qq!$app_serv{$self}/exec/remotecmd?auth=${sig}&cmd=${cmd}%20${addr}! . ( $args ? '&' . $args : '' );
    print STDERR "Sending command: $auth\n" if $Debug;
    my $req = HTTP::Request->new( GET => $auth );
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

    print STDERR "Done parsing form\n" if $Trace;
    unless( scalar(@forms) ) {
        $self->errors("No forms found!");
        $self->err_pages($res);
        return;
    }

  FORMS: for my $frm ( @forms ) {
        print STDERR "Comparing form action...\n" if $Debug;
	unless( $frm->action =~ $action ) {
            print STDERR "Skipping (" . $frm->action . " !~ $action)\n" if $Debug;
            next FORMS;
        }

        print STDERR "Got a match form action match...\n" if $Debug;

        ## we have more criteria to weed out the form we want
        if( keys %$inputs ) {
            my $input_match;

            print STDERR "Refining form search because inputs detected...\n" if $Debug;
          FORM_INPUT: for my $finput ( $frm->inputs ) {
                print STDERR "Dumping input from form: " . Dumper($finput) if $Debug;
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

            next FORMS unless $input_match;
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

=head2 list_organizations

Returns a hashref of organizations in this form:

  { orgid => <orgdata> }

where orgdata is a hashref in this form:

  { key => value }

This structure may vary from time to time, based on what is returned
from Postini's "Download Orgs/Settings" link. You may use something
like B<Data::Dumper> to discover the keys and values returned in this
method.

=head2 set_org_data( %parms )

Sets organization data. Currently, only the General Settings are supported.

GeneralSettings options:

Arguments (and values, if applicable):

=over 4

=item B<section>

GeneralSettings

=item B<name>

=item B<orgtag>

=item B<parent>

=item B<support_contact>

=item B<api_secret>

=item B<tight_postini>

=item B<default_user>

=item B<smartcreate>

=item B<quar_links>

=item B<timezone>

=item B<lang>

=item B<encoding>

=item B<cascade>

=back

=head2 set_org_mail_server( %parms )

Sets the mail server for an organization, as well as load-balancing
and connection limit settings

  $mp->set_org_mail_server( server1 => 'box.hosting.tld',
                            weight1 => 100,
                            maxcon1 => 500,

                            failover1  => 'backup.hosting.tld',
                            fo_weight1 => 100,
                            fo_maxcon1 => 300,
                           );

You may specify as many serverN, pconnN and limitN as you wish (but
Postini may have internal limits).

=head2 delete_organization ( $organization_name )

Deletes an organization. All domains must be deleted from the
organization first.

Example:

  $mp->delete_organization( org => 'Old Sub-Org' );

=head2 org_from_domain ( $domain )

Returns the organization id that is the immediate parent of the given domain.

=head2 list_users ( %criteria )

Returns a hashref in the form of 'username => user data' for all users
that match the given criteria. Currently 'user', 'domain', 'org', and
'orgid' criteria are supported.

Example:

  ## retrieve all users for this domain
  my $users = $mp->list_users( domain => 'saltpatio.com' );

=head2 list_aliases ( %criteria )

Returns a hashref of users and aliases in the form:

 { user1 => [ alias1, alias2 ],
   user2 => [ alias1, ... ],
   ... }

This method takes the same criteria as list_users().

Example:

  my $aliases = $mp->list_aliases( domain => 'saltpatio.com' );
  print "Aliases for joe: " . join("\n", @{$aliases->{'joe@saltpatio.com'}}) . "\n";

=head2 get_user_data ( $username )

Retrieves the current settings for a user in the form of a hash.

Example:

  my %data = $mp->get_user_data('joe@domain.tld');

B<get_user_data> is a shortcut for:

  my %data = %{ $mp->list_users( user => 'joe@domain.tld' ) };

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

=head2 add_user ( $username, [ field => value, ... ] )

Adds an email address to a Postini domain. When the user is added,
Postini will filter mail for it. The domain must be added to an
organization prior to you adding the user.

Example:

  $mp->add_user( 'joe@somedomain.tld' );

=head2 delete_user ( $username )

Deletes an email address from a Postini configuration.

Example:

  $mp->delete_user( 'joe@somedomain.tld' );

=head2 reset_user_password ( %args )

Resets a user's password. Arguments:

=over 4

=item B<user>

The email address to change passwords for

=item B<password>

If specified, we'll use this password for the new password. Otherwise
a new password will be generated and sent to the user.

=item B<notify>

If specified, email the user their new password (this only applies if
a password is supplied).

=back

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
