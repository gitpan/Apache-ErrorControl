
#
#   description: Apache Error Templating Engine
#
#   author: DJ <dj@boxen.net>
#
# $Id: ErrorControl.pm,v 1.15 2004/05/02 10:02:24 dj Exp $

package Apache::ErrorControl;

use strict;
use warnings;

# BEGIN BLOCK {{{
BEGIN {
  ## Modules
  use HTML::Template::Set;
  use Apache::Constants qw(:common);
  use Apache::File ();
  use Class::Date;

  ## Constants
  use constant TRUE  => 1;
  use constant FALSE => 0;

  ## Variables
  use vars (qw($VERSION));

  $VERSION = do {my @r=(q$Revision: 1.15 $=~/\d+/g); sprintf "%d."."%03d"x$#r,@r};
}
# }}}


# Handler Function {{{
sub handler {
  my $r = shift;
  my $self = bless({}, __PACKAGE__);

  # Define Variables {{{
  my $file          = $r->filename;
  my $c             = $r->connection;
  my $s             = $r->server;

  # check for test mode/hardcoded mode
  if ($r->uri() =~ /(\d{2,3})[\/]*$/) {
    $self->{error_code} = $1;
  } else {
    $self->{error_code} = ($r->prev()) ?
      $r->prev()->status() : $r->status();
  }

  $self->{document_root} = $r->document_root();

  unless (exists $self->{error_code} and $self->{error_code}) {
    die "Unable to find Error Code, very odd!\n";
  }

  $self->{template_dir} = $r->dir_config("TemplateDir");
  $self->{default_template} = $r->dir_config("DefaultTemplate");

  my $template = $self->find_error_template();

  unless (defined $template and -f $template) {
    die "Unable to find DefaultTemplate or derrived template!\n";
  }

  # try and derrive the MTA Program and setup the email_on hash
  my $MTA_Prog;
  my %email_on = ();
  my $disable_email = $r->dir_config("DisableEmail");
  unless ($disable_email) {
    $MTA_Prog = $r->dir_config("MTA");
    unless (defined $MTA_Prog and -f $MTA_Prog) {
      if (-f "/var/qmail/bin/qmail-inject") {
        $MTA_Prog = "/var/qmail/bin/qmail-inject";
      } elsif (-f "/usr/sbin/sendmail") {
        $MTA_Prog = "/usr/sbin/sendmail";
      } elsif (-f "/usr/lib/sendmail") {
        $MTA_Prog = "/usr/lib/sendmail";
      }
    }
    # build the email_on hash, defaulting to 500
    my @email_on = $r->dir_config("EmailOn");
    if (@email_on) {
      foreach my $ec (@email_on) {
        next unless (defined $ec and $ec);
        $email_on{$ec} = TRUE;
      }
    } else {
      $email_on{'500'} = TRUE;
    }
  }

  my $date_format = $r->dir_config("DateFormat");
  # }}}


  # Load Template {{{
  my %tmpl_args = ();
  if ($self->{template_dir}) {
    $tmpl_args{path} = $self->{template_dir};
  }

  my $tmpl = new HTML::Template::Set(
    %tmpl_args,
    filename      => $template,
    cache         => TRUE,
    associate_env => TRUE
  );
  # }}}


  # Setup Template Params {{{

  # build a hash of the params, so we dont try and set anything that doesnt
  # exist in the template
  my %params;
  map { $params{$_} = TRUE } $tmpl->param();

  # build a list of 'emails' to send messages to if a error 500 is encountered
  # (internal server error). also if the 'webmaster_email' TMPL_VAR is the
  # same as the server_admin only send the email once.
  my (@email) = ();
  unless ($disable_email) {
    if (exists $params{'webmaster_email'}) {
      my $webmaster_email = $tmpl->param('webmaster_email');
      unless ($webmaster_email eq $s->server_admin()) {
        push(@email, $s->server_admin());
      }
      push(@email, $webmaster_email);
    } elsif ($s->server_admin()) {
      push(@email, $s->server_admin());
    }
  }

  # set the current error_code's TMPL_IF on (if the TMPL_IF exists)
  #  i.e. <TMPL_IF NAME="404">
  if (exists $params{$self->{error_code}}) {
    $tmpl->param( $self->{error_code} => TRUE );
  } elsif (exists $params{'unknown_error'}) {
    $tmpl->param( unknown_error => TRUE );
  }
  # set the error_code TMPL_VAR
  #   i.e. <TMPL_VAR NAME="error_code"> (which is substituted with 404)
  if (exists $params{error_code}) {
    $tmpl->param( error_code => $self->{error_code} );
  }

  # load the 'date_format' from the template if its set
  if (exists $params{date_format}) {
    $date_format = $tmpl->param('date_format');
  }

  # make the date string (formatted or default)
  my $formatted_date;
  if (exists $params{date}) {
    my $date = new Class::Date(time);
    if ($date_format) {
      $formatted_date = $date->strftime($date_format);
    } else {
      $formatted_date = $date->string();
    }
    $tmpl->param( date => $formatted_date );
  }

  # build the 'requestor' TMPL_VAR (made up from the remote host/ip)
  my $requestor;
  my $remote_host = $c->remote_host();
  my $remote_ip   = $c->remote_ip();
  if ($remote_host and $remote_ip) {
    $requestor = $remote_host. ' ('. $remote_ip. ')';
  } elsif ($remote_ip) {
    $requestor = $remote_ip;
  } else {
    $requestor = 'unknown';
  }

  # use the r->user in the requestor if its available
  if ($c->user()) {
    $requestor = $c->user(). ' ('. $requestor. ')';
  }

  if (exists $params{requestor}) {
    $tmpl->param( requestor => $requestor );
  }

  # build the 'base_url' TMPL_VAR (made up from the server_name etc)
  my $base_url;
  if (exists $ENV{'HTTPS'} and $ENV{'HTTPS'}) {
    $base_url = 'https://';
  } else {
    $base_url = 'http://';
  }
  $base_url .= $s->server_hostname();

  if (exists $params{base_url}) {
    $tmpl->param( base_url => $base_url );
  }

  # build the 'request_url' TMPL_VAR (made up from the base_urlm
  # the url and the args)
  my $request_url = $base_url;
  if ($r->prev()) {
    $request_url .= $r->prev()->uri();
    if ($r->prev()->args()) {
      $request_url .= '?'. $r->prev()->args();
    }
  } else {
    $request_url .= $r->uri();
    if ($r->args()) {
      $request_url .= '?'. $r->args();
    }
  }

  if (exists $params{request_url}) {
    $tmpl->param( request_url => $request_url );
  }
  # }}}


  # Send Email For Internal Server Error {{{
  unless ($disable_email) {
    if (exists $email_on{$self->{error_code}} and defined $MTA_Prog 
    and -f $MTA_Prog) {
      foreach my $email_address (@email) {
        open(MTA,"|$MTA_Prog");
        print MTA "To: $email_address\n";
        print MTA "From: Apache::ErrorControl <errorcontrol\@".
          $s->server_hostname.">\n";
        print MTA "Subject: Error ". $self->{error_code}. " on ".
          $s->server_hostname."\n\n";
        print MTA "Time: ". $formatted_date. "\n";
        print MTA "Requested URL: ". $request_url. "\n";
        print MTA "Requested By: ". $requestor. "\n\n";
        print MTA "--------------------\n";
        print MTA "Apache::ErrorControl\n\n";
        close(MTA);
      }
    }
  }
  # }}}


  # Send Headers {{{
  $r->content_type('text/html; charset=ISO-8859-1');
  $r->send_http_header;
  # }}}


  # Send Template {{{
  print $tmpl->output();
  # }}}

  return;
}
# }}}


# Find Error Template Function {{{
#  im not sure why I chose to allow so many paths/filenames but I think its
#  better to be flexiable.
sub find_error_template {
  my ($self) = @_;

  my $error_code = $self->{error_code} || undef;

  my @paths;
  if ($self->{document_root}) {
    push(@paths, $self->{document_root});
  }
  if ($self->{template_dir}) {
    push(@paths, $self->{template_dir});
  }

  foreach my $path (@paths) {
    if (defined $error_code) {
      if (-f $path. '/'. $error_code) {
        return $path. '/'. $error_code;
      } elsif (-f $path. '/'. $error_code. '.html') {
        return $path. '/'. $error_code. '.html';
      } elsif (-f $path. '/'. $error_code. '.tmpl') {
        return $path. '/'. $error_code. '.tmpl';
      }
    }
    if (-f $path. '/allerrors') {
      return $path. '/allerrors';
    } elsif (-f $path. '/allerrors.html') {
      return $path. '/allerrors.html';
    } elsif (-f $path. '/allerrors.tmpl') {
      return $path. '/allerrors.tmpl';
    }
  }

  if (exists $self->{default_template} and $self->{default_template}) {
    if (-f $self->{default_template}) {
      return $self->{default_template};
    } elsif (-f $self->{template_dir}. '/'. $self->{default_template}) {
      return $self->{template_dir}. '/'. $self->{default_template};
    } elsif (-f $self->{document_root}. '/'. $self->{default_template}) {
      return $self->{document_root}. '/'. $self->{default_template};
    }
  }
}
# }}}

1;

END { }

__END__

=pod

=head1 NAME

Apache::ErrorControl - Apache Handler for Templating Apache Error Documents

=head1 SYNOPSIS

in your httpd.conf

  PerlModule Apache::ErrorControl

  <Location /error>
    SetHandler perl-script
    PerlHandler Apache::ErrorControl

    PerlSetVar TemplateDir /usr/local/apache/templates
  </Location>

  ErrorDocument 400 /error
  ErrorDocument 401 /error
  ErrorDocument 402 /error
  ErrorDocument 403 /error
  ErrorDocument 404 /error
  ErrorDocument 500 /error

in your template (allerrors.tmpl):

  <TMPL_SET NAME="webmaster_email">dj@boxen.net</TMPL_SET>

  <HTML>
    <HEAD>
      <TITLE>Error <TMPL_VAR NAME="error_code"></TITLE>
    </HEAD>

    <BODY>
      <TMPL_IF NAME="404">
        <H1>Error 404: File Not Found</H1>
        <HR><BR>

        <p>The file you were looking for is not here, we must have
          deleted it - or you just might be mentally retarded</p>
      </TMPL_IF>
      <TMPL_IF NAME="500">
        <H1>Error 500: Internal Server Error</H1>
        <HR><BR>

        <p>We are currently experiencing problems with our server,
          please call back later</p>
      </TMPL_IF>

      <p><b>Time of Error:</b> <TMPL_VAR NAME="date"></p>
      <p><b>Requested From:</b> <TMPL_VAR NAME="requestor"></p>
      <p><b>Requested URL:</b> <TMPL_VAR NAME="request_url"></p>
      <p><b>Website Base URL:</b> <TMPL_VAR NAME="base_url"></p>
      <p><b>Contact Email:</b> support@mouse.com</p>
    </BODY>
  </HTML>

=head1 DESCRIPTION

This mod_perl content handler will make templating your ErrorDocument pages
easy. Basically you add a couple of entries to your httpd.conf file restart
apache, make your template and your cruising.

The module uses L<HTML::Template::Set> (which is essentially HTML::Template
with the ability to use TMPL_SET tags). So for help templating your error
pages please see: L<HTML::Template::Set> and L<HTML::Template>. Also check
the B<OPTIONS> section of this documentation for available TMPL_SET/TMPL_IF
and TMPL_VAR params.

By default when an error 500 (internal server error) is encountered the
I<server admin> is emailed (along with the B<webmaster_email> if its defined,
see: B<OPTIONS>). This functionality can be disabled all together with the
B<DisableEmail> option or enhanced with the B<EmailOn> option.

Templates are looked up in the following order: the document_root is scanned
for 'allerrors', 'allerrors.tmpl', I<error_code> or I<error_code>.tmpl. if
no templates are found the B<TemplateDir> is scanned for the same files. if
no templates are found the B<DefaultTemplate> is used and if its not set
the system 'B<die>s'.

Because so many places are checked for the templates its possible to have
one global error handler and have different templates for each virtual host
and also allow for defaults. It also means you can have a general catch-all
template (allerrors/allerrors.tmpl) as well as single templates (i.e. 500.tmpl).
Generally I just use allerrors.tmpl and use TMPL_IF's to display custom content
per error message, but you can set it up any way you want.

=head1 MOTIVATION

I wanted to write a mod_perl handler so I could template error messages.
I also wanted to make it extensible enough that I could have a global error
handler and it would cover all the virtual webservers and have different
templates for each of them - ala - the birth of Apache::ErrorControl.

=head1 TESTING

Obviously you will need the ability to test your templates, and trying to
generate each error code would be a pain in the ass. So to counter this I have
implemented a B<testing>/B<static> mode. Basically you call the handler with
"/I<error_code>" tacked on the end. You can also use this to define static
error pages if you dont want the system to "automagically" determine the
I<error_code>.

to test error 401:

  http:/www.abc.com/error/401

to statically configure error 401:

  ErrorDocument 401 /error/401

I dont see why you would want to statically configure an error code, unless
of course you run into problems for some reason and are forced to.

=head1 OPTIONS

=over 4

=item HTTPD CONFIG PerlSetVar's

=over 4

=item *

B<TemplateDir> - the directory of your templates, this path will be used
when looking up the template for the error message (looking in it for either
I<error_code>, I<error_code>.tmpl, allerrors, allerrors.tmpl - then falling back
to looking for the files mentioned before under the document_root - then
falling back to using the B<DefaultTemplate> - then 'B<die>ing').
the B<TemplateDir> is also passed to L<HTML::Template::Set> as the B<path>.

  PerlSetVar TemplateDir "/usr/local/apache/templates"

=item *

B<DefaultTemplate> - the default template file to use, can be just a filename
(to be looked up under B<TemplateDir>) or the full path to the file.

  PerlSetVar DefaultTemplate "myerrors.tmpl"

=item *

B<MTA> - (mail transit authority), basically the path to the program to send
email with (i.e. sendmail, qmail-send etc). dont forget to provide any options
needed for your MTA to function correctly (i.e. B<-t> for sendmail).

  PerlSetVar MTA "/usr/lib/sendmail -t"

=item *

B<DateFormat> - you can specify the date format to use in emails and in the
templates here. just provide a strftime format. this can be overrided on a
per template basis with the B<date_format> TMPL_SET param. if this isnt
specified a default date format is used.

  PerlSetVar DateFormat "%Y-%m-%d %H:%M:%S"

=item *

B<DisableEmail> - if you want to disable error emails all together then
set this to true.

  PerlSetVar DisableEmail 1

=item *

B<EmailOn> - if you want to recieve emails for more than just internal
server errors (500) then specify an EmailOn for each using a PerlAddVar
instead of a PerlSetVar.

  PerlAddVar EmailOn 403
  PerlAddVar EmailOn 500

=back

=item Template Options

=over 4

=item TMPL_SET

=over 4

=item *

B<webmaster_email> - setting this param enables the error email to be sent
to some place other than just the server_admin, however unless this address
is the same as the server admin's email an email is sent to both places.

  <TMPL_SET NAME="webmaster_email">dj@abc.com</TMPL_SET>

=item *

B<date_format> - this option overrides the B<DateFormat> HTTPD CONF entry
on a per-template basis.

  <TMPL_SET NAME="date_format">%d-%m-%Y %H:%M:S</TMPL_SET>

=back

=item TMPL_VAR/TMPL_IF

=over 4

=item *

B<requestor> - the requestor of the page either "user (hostname (ip))",
"user (ip)", "hostname (ip)" or "ip", depending if their ip resolves or not.
NB: unless you have "HostnameLookups On" in you httpd.conf you will never
see the users hostname.

  <TMPL_VAR NAME="requestor">

=item *

B<base_url> - the base url of the website, i.e. http://www.abc.com

  <TMPL_VAR NAME="base_url">

=item *

B<request_url> - the full request url including arguments, i.e.
http://www.abc.com/stuff/stuffed.cgi?abc=yes&no=yes

  <TMPL_VAR NAME="request_url">

=item *

B<date> - the date/time of the error (format depending on the 
B<DateFormat>/B<date_format>.

  <TMPL_VAR NAME="date">

=item *

B<error_code> - the error code, i.e. 404, 403, 500 etc

  <TMPL_VAR NAME="error_code">

=item *

B<*error_code*> - the actual error code itself is set as a param (if the
param exists). if there is no TMPL_IF or TMPL_VAR
defined for the error code encountered the param B<unknown_error> is turned on
(obviously only if it too is defined).
personally I cant see why anyone would ever need B<unknown_error> but ive
added it here anyways.

  <TMPL_IF NAME="404">
    Error 404 - File Not Found
  </TMPL_IF>

=item *

B<unknown_error> - if the B<*error_code*> is not defined as a TMPL_VAR or
TMPL_IF and there is a TMPL_IF/TMPL_VAR by the name of B<unknown_error> it is
set to TRUE (1). as mentioned above I cannot see why anyone would want this.

  <TMPL_IF NAME="unknown_error">
    Error <TMPL_VAR NAME="error_code"> - Unknown
  </TMPL_IF>

=item *

B<env_*> - all env_* params are available, see L<HTML::Template::Set>
for details.

  <TMPL_VAR NAME="env_server_name">

=back

=back

=back

=head1 CAVEATS

This module may be missing something that you feel it needs, it has
everything I have wanted thou. If you want a feature added please email me
or send me a patch.

=head1 BUGS

I am aware of no bugs - if you find one, just drop me an email and i'll
try and nut it out (or email a patch, that would be tops!).

=head1 SEE ALSO

L<HTML::Template::Set>, L<HTML::Template>, L<Apache>

=head1 AUTHOR

David J Radunz <dj@boxen.net>

=head1 LICENSE

HTML::Template::Set : HTML::Template extension adding set support

Copyright (C) 2004 David J Radunz (dj@boxen.net)

This module is free software; you can redistribute it and/or modify it
under the terms of either:

a) the GNU General Public License as published by the Free Software
Foundation; either version 1, or (at your option) any later version,
or

b) the "Artistic License" which comes with this module.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either
the GNU General Public License or the Artistic License for more details.

You should have received a copy of the Artistic License with this
module, in the file ARTISTIC.  If not, I'll be glad to provide one.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
USA

