
# _{name} methods are undocumented and meant to be private.

use strict;
use warnings;

package Mail::IMAPClient;
our $VERSION = '3.19';

use Mail::IMAPClient::MessageSet;

use IO::Socket qw(:crlf SOL_SOCKET SO_KEEPALIVE);
use IO::Select ();
use IO::File   ();
use Carp qw(carp);    #local $SIG{__WARN__} = \&Carp::cluck; #DEBUG

use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EAGAIN EPIPE ECONNRESET);
use List::Util qw(first min max sum);
use MIME::Base64 qw(encode_base64 decode_base64);
use File::Spec ();

use constant APPEND_BUFFER_SIZE => 1024 * 1024;

use constant {
    Unconnected   => 0,
    Connected     => 1,    # connected; not logged in
    Authenticated => 2,    # logged in; no mailbox selected
    Selected      => 3,    # mailbox selected
};

use constant {
    INDEX => 0,    # Array index for output line number
    TYPE  => 1,    # Array index for line type (OUTPUT, INPUT, or LITERAL)
    DATA  => 2,    # Array index for output line data
};

use constant NonFolderArg => 1;    # for Massage indicating non-folder arguments

my %SEARCH_KEYS = map { ( $_ => 1 ) } qw(
  ALL ANSWERED BCC BEFORE BODY CC DELETED DRAFT FLAGGED
  FROM HEADER KEYWORD LARGER NEW NOT OLD ON OR RECENT
  SEEN SENTBEFORE SENTON SENTSINCE SINCE SMALLER SUBJECT
  TEXT TO UID UNANSWERED UNDELETED UNDRAFT UNFLAGGED
  UNKEYWORD UNSEEN);

sub _debug {
    my $self = shift;
    return unless $self->Debug;

    my $text = join '', @_;
    $text =~ s/$CRLF/\n  /og;
    $text =~ s/\s*$/\n/;

    #use POSIX (); $text = POSIX::strftime("%F %T ", localtime).$text; #DEBUG
    my $fh = $self->{Debug_fh} || \*STDERR;
    print $fh $text;
}

BEGIN {

    # set-up accessors
    foreach my $datum (
        qw(Authcallback Authmechanism Authuser Buffer Count Debug
        Debug_fh Domain Folder Ignoresizeerrors Keepalive
        Maxcommandlength Maxtemperrors Password Peek Port
        Prewritemethod Proxy Ranges Readmethod Reconnectretry
        Server Showcredentials State Supportedflags Timeout Uid
        User Ssl)
      )
    {
        no strict 'refs';
        *$datum = sub {
            @_ > 1 ? ( $_[0]->{$datum} = $_[1] ) : $_[0]->{$datum};
        };
    }
}

sub LastError {
    my $self = shift;
    @_ or return $self->{LastError};
    my $err = shift;

    # allow LastError to be reset with undef
    if ( defined $err ) {
        $err =~ s/$CRLF$//og;
        local ($!);    # old versions of Carp could reset $!
        $self->_debug( Carp::longmess("ERROR: $err") );

        # hopefully this is rare...
        if ( $err eq "NO not connected" ) {
            my $lerr = $self->{LastError} || "";
            my $emsg = "Trying command when NOT connected!";
            $emsg .= " LastError was: $lerr" if $lerr;
            Carp::cluck($emsg);
        }
    }
    $@ = $self->{LastError} = $err;
}

sub Fast_io(;$) {
    my ( $self, $use ) = @_;
    defined $use
      or return $self->{File_io};

    my $socket = $self->{Socket}
      or return undef;

    unless ($use) {
        eval { fcntl( $socket, F_SETFL, delete $self->{_fcntl} ) }
          if exists $self->{_fcntl};
        $@ = '';
        $self->{Fast_io} = 0;
        return undef;
    }

    my $fcntl = eval { fcntl( $socket, F_GETFL, 0 ) };
    if ($@) {
        $self->{Fast_io} = 0;
        $self->_debug("not using Fast_IO; not available on this platform")
          unless $self->{_fastio_warning_}++;
        $@ = '';
        return undef;
    }

    $self->{Fast_io} = 1;
    my $newflags = $self->{_fcntl} = $fcntl;
    $newflags |= O_NONBLOCK;
    fcntl( $socket, F_SETFL, $newflags );
}

# removed
sub EnableServerResponseInLiteral { undef }

sub Wrap { shift->Clear(@_) }

# The following class method is for creating valid dates in appended msgs:
my @dow = qw(Sun Mon Tue Wed Thu Fri Sat);
my @mnt = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub Rfc822_date {
    my $class = shift;    #Date: Fri, 09 Jul 1999 13:10:55 -0000#
    my $date = $class =~ /^\d+$/ ? $class : shift;    # method or function?
    my @date = gmtime $date;

    sprintf(
        "%s, %02d %s %04d %02d:%02d:%02d -%04d",
        $dow[ $date[6] ],
        $date[3],
        $mnt[ $date[4] ],
        $date[5] + 1900,
        $date[2], $date[1], $date[0], $date[8]
    );
}

# The following methods create valid dates for use in IMAP search strings
sub Rfc2060_date {
    my $class = shift;                                 # 11-Jan-2000
    my $stamp = $class =~ /^\d+$/ ? $class : shift;    # method or function
    my @date  = gmtime $stamp;

    sprintf( "%02d-%s-%04d", $date[3], $mnt[ $date[4] ], $date[5] + 1900 );
}

sub Rfc2060_datetime($;$) {
    my ( $class, $stamp, $zone ) = @_;    # 11-Jan-2000 04:04:04 +0000
    $zone ||= '+0000';
    my @date = gmtime $stamp;

    sprintf(
        "%02d-%s-%04d %02d:%02d:%02d %s",
        $date[3],
        $mnt[ $date[4] ],
        $date[5] + 1900,
        $date[2], $date[1], $date[0], $zone
    );
}

# Change CRLF into \n
sub Strip_cr {
    my $class = shift;
    if ( !ref $_[0] && @_ == 1 ) {
        ( my $string = $_[0] ) =~ s/$CRLF/\n/og;
        return $string;
    }

    return wantarray
      ? map { s/$CRLF/\n/og; $_ } ( ref $_[0] ? @{ $_[0] } : @_ )
      : [ map { s/$CRLF/\n/og; $_ } ( ref $_[0] ? @{ $_[0] } : @_ ) ];
}

# The following defines a special method to deal with the Clear parameter:
sub Clear {
    my ( $self, $clear ) = @_;
    defined $clear or return $self->{Clear};

    my $oldclear = $self->{Clear};
    $self->{Clear} = $clear;

    my @keys = reverse $self->_trans_index;

    for ( my $i = $clear ; $i < @keys ; $i++ ) {
        delete $self->{History}{ $keys[$i] };
    }

    return $oldclear;
}

# read-only access to the transaction number
sub Transaction { shift->Count }

# remove doubles from list
sub _remove_doubles(@) {
    my %seen;
    grep { !$seen{$_}++ } @_;
}

# the constructor:
sub new {
    my $class = shift;
    my $self  = {
        LastError        => "",
        Uid              => 1,
        Count            => 0,
        Fast_io          => 1,
        Clear            => 5,
        Keepalive        => 0,
        Maxcommandlength => 1000,
        Maxtemperrors    => 'unlimited',
        State            => Unconnected,
        Authmechanism    => 'LOGIN',
        Port             => 143,
        Timeout          => 600,
        History          => {},
    };
    while (@_) {
        my $k = ucfirst lc shift;
        my $v = shift;
        $self->{$k} = $v if defined $v;
    }
    bless $self, ref($class) || $class;

    if ( my $sup = $self->{Supportedflags} ) {    # unpack into case-less HASH
        my %sup = map { m/^\\?(\S+)/ ? lc $1 : () } @$sup;
        $self->{Supportedflags} = \%sup;
    }

    $self->{Debug_fh} ||= \*STDERR;
    CORE::select( ( select( $self->{Debug_fh} ), $|++ )[0] );

    if ( $self->Debug ) {
        $self->_debug( "Started at " . localtime() );
        $self->_debug("Using Mail::IMAPClient version $VERSION on perl $]");
    }

    # BUG? return undef on Socket() failure?
    $self->Socket( $self->{Socket} )
      if $self->{Socket};

    if ( $self->{Rawsocket} ) {
        my $sock = delete $self->{Rawsocket};

        # Ignore Rawsocket if Socket is set.  BUG? should we carp/croak?
        $self->RawSocket($sock) unless $self->{Socket};
    }

    !$self->{Socket} && $self->{Server} ? $self->connect : $self;
}

sub connect(@) {
    my $self = shift;

    # BUG? We should restrict which keys can be passed/set here.
    %$self = ( %$self, @_ ) if @_;

    my $server  = $self->Server;
    my $port    = $self->Port;
    my @timeout = $self->Timeout ? ( Timeout => $self->Timeout ) : ();
    my $sock;

    if ( File::Spec->file_name_is_absolute($server) ) {
        $self->_debug("Connecting to unix socket $server @timeout");
        $sock = IO::Socket::UNIX->new(
            Peer  => $server,
            Debug => $self->Debug,
            @timeout
        );
    }
    else {
        my $ioclass = "IO::Socket::INET";
        if ( $self->Ssl ) {
            $ioclass = "IO::Socket::SSL";
            eval "require $ioclass";
            if ($@) {
                $self->LastError("Unable to load '$ioclass' for Ssl: $@");
                return undef;
            }
        }

        $self->_debug("Connecting via $ioclass to $server:$port @timeout");
        $sock = $ioclass->new(
            PeerAddr => $server,
            PeerPort => $port,
            Proto    => 'tcp',
            Debug    => $self->Debug,
            @timeout
        );
    }

    unless ($sock) {
        $self->LastError("Unable to connect to $server: $@");
        return undef;
    }

    $self->_debug( "Connected to $server" . ( $! ? " errno($!)" : "" ) );
    $self->Socket($sock);
}

sub RawSocket(;$) {
    my ( $self, $sock ) = @_;
    defined $sock
      or return $self->{Socket};

    $self->{Socket}  = $sock;
    $self->{_select} = IO::Select->new($sock);

    delete $self->{_fcntl};
    $self->Fast_io( $self->Fast_io );

    $sock;
}

sub Socket($) {
    my ( $self, $sock ) = @_;
    defined $sock
      or return $self->{Socket};

    $self->RawSocket($sock);
    $self->State(Connected);

    setsockopt( $sock, SOL_SOCKET, SO_KEEPALIVE, 1 ) if $self->Keepalive;

    # LastError may be set by _read_line via _get_response
    # look for "* (OK|BAD|NO|PREAUTH)"
    my $code = $self->_get_response( '*', 'PREAUTH' ) or return undef;

    if ( $code eq 'BYE' || $code eq 'NO' ) {
        $self->State(Unconnected);
        return undef;
    }
    elsif ( $code eq 'PREAUTH' ) {
        $self->State(Authenticated);
        return $self;
    }

    $self->User && $self->Password ? $self->login : $self;
}

sub login {
    my $self = shift;
    my $auth = $self->Authmechanism;
    return $self->authenticate( $auth, $self->Authcallback )
      if $auth && $auth ne 'LOGIN';

    my $passwd = $self->Password;
    my $id     = $self->User;

    return undef unless ( defined($passwd) and defined($id) );

    if ( $passwd =~ m/\W/ ) {    # need to quote
        $passwd =~ s/(["\\])/\\$1/g;
        $passwd = qq("$passwd");
    }

    $id = qq("$id") if $id !~ /^".*"$/;

    $self->_imap_command("LOGIN $id $passwd")
      or return undef;

    $self->State(Authenticated);
    $self;
}

sub noop {
    my ( $self, $user ) = @_;
    $self->_imap_command("NOOP") ? $self->Results : undef;
}

sub proxyauth {
    my ( $self, $user ) = @_;
    $self->_imap_command("PROXYAUTH $user") ? $self->Results : undef;
}

sub separator {
    my ( $self, $target ) = @_;
    unless ( defined $target ) {

        # separator is namespace's 1st thing's 1st thing's 2nd thing:
        my $ns = $self->namespace or return undef;
        if ($ns) {
            my $sep = $ns->[0][0][1];
            return $sep if $sep;
        }
        $target = '';
    }

    return $self->{separators}{$target}
      if exists $self->{separators}{$target};

    my $list = $self->list( undef, $target ) or return undef;

    foreach my $line (@$list) {
        my $rec = $self->_list_or_lsub_response_parse($line);
        next unless defined $rec->{name};
        $self->{separators}{ $rec->{name} } = $rec->{delim};
    }
    return $self->{separators}{$target};
}

# BUG? caller gets empty list even if Error
# - returning an array with a single undef value seems even worse though
sub sort {
    my ( $self, $crit, @a ) = @_;

    $crit =~ /^\(.*\)$/    # wrap criteria in parens
      or $crit = "($crit)";

    my @hits;
    if ( $self->_imap_uid_command( SORT => $crit, @a ) ) {
        my @results = $self->History;
        foreach (@results) {
            chomp;
            s/$CR$//;
            s/^\*\s+SORT\s+// or next;
            push @hits, grep /\d/, split;
        }
    }
    return wantarray ? @hits : \@hits;
}

sub _list_or_lsub {
    my ( $self, $cmd, $reference, $target ) = @_;
    defined $reference or $reference = '';
    defined $target    or $target    = '*';
    length $target     or $target    = '""';

    $target eq '*' || $target eq '""'
      or $target = $self->Massage($target);

    $self->_imap_command(qq($cmd "$reference" $target))
      or return undef;

    # cleanup any literal data that may be returned
    my $ret = wantarray ? [ $self->History ] : $self->Results;
    if ($ret) {
        my $cmd = wantarray ? undef : shift @$ret;
        $self->_list_response_preprocess($ret);
        unshift( @$ret, $cmd ) if defined($cmd);
    }

    #return wantarray ? $self->History : $self->Results;
    return wantarray ? @$ret : $ret;
}

sub list { shift->_list_or_lsub( "LIST", @_ ) }
sub lsub { shift->_list_or_lsub( "LSUB", @_ ) }

sub _folders_or_subscribed {
    my ( $self, $method, $what ) = @_;
    my @folders;

    # do BLOCK allowing use of "last if undef/error" and avoiding dup code
    do {
        {
            my @list;
            if ($what) {
                my $sep = $self->separator($what);
                last unless defined $sep;

                my $whatsub = $what =~ m/\Q${sep}\E$/ ? "$what*" : "$what$sep*";

                my $tref = $self->$method( undef, $whatsub ) or last;
                shift @$tref;    # remove command
                push @list, @$tref;

                my $exists = $self->exists($what) or last;
                if ($exists) {
                    $tref = $self->$method( undef, $what ) or last;
                    shift @$tref;    # remove command
                    push @list, @$tref;
                }
            }
            else {
                my $tref = $self->$method( undef, undef ) or last;
                shift @$tref;        # remove command
                push @list, @$tref;
            }

            foreach my $resp (@list) {
                my $rec = $self->_list_or_lsub_response_parse($resp);
                next unless defined $rec->{name};
                push @folders, $rec->{name};
            }
        }
    };

    my @clean = _remove_doubles @folders;
    return wantarray ? @clean : \@clean;
}

sub folders {
    my ( $self, $what ) = @_;

    return wantarray ? @{ $self->{Folders} } : $self->{Folders}
      if !$what && $self->{Folders};

    my @folders = $self->_folders_or_subscribed( "list", $what );
    $self->{Folders} = \@folders unless $what;
    return wantarray ? @folders : \@folders;
}

sub subscribed {
    my ( $self, $what ) = @_;
    my @folders = $self->_folders_or_subscribed( "lsub", $what );
    return wantarray ? @folders : \@folders;
}

# BUG? cleanup escaping/quoting
sub deleteacl {
    my ( $self, $target, $user ) = @_;
    $target = $self->Massage($target);
    $user =~ s/^"(.*)"$/$1/;
    $user =~ s/"/\\"/g;

    $self->_imap_command(qq(DELETEACL $target "$user"))
      or return undef;

    return wantarray ? $self->History : $self->Results;
}

# BUG? cleanup escaping/quoting
sub setacl {
    my ( $self, $target, $user, $acl ) = @_;
    $target ||= $self->Folder;
    $target = $self->Massage($target);

    $user ||= $self->User;
    $user =~ s/^"(.*)"$/$1/;
    $user =~ s/"/\\"/g;

    $acl =~ s/^"(.*)"$/$1/;
    $acl =~ s/"/\\"/g;

    $self->_imap_command(qq(SETACL $target "$user" "$acl"))
      or return undef;

    return wantarray ? $self->History : $self->Results;
}

sub getacl {
    my ( $self, $target ) = @_;
    defined $target or $target = $self->Folder;
    my $mtarget = $self->Massage($target);
    $self->_imap_command(qq(GETACL $mtarget))
      or return undef;

    my @history = $self->History;
    my $hash;
    for ( my $x = 0 ; $x < @history ; $x++ ) {
        next if $history[$x] !~ /^\* ACL/;

        my $perm =
            $history[$x] =~ /^\* ACL $/
          ? $history[ ++$x ] . $history[ ++$x ]
          : $history[$x];

        $perm =~ s/\s?$CRLF$//o;
        until ( $perm =~ /\Q$target\E"?$/ || !$perm ) {
            $perm =~ s/\s([^\s]+)\s?$// or last;
            my $p = $1;
            $perm =~ s/\s([^\s]+)\s?$// or last;
            my $u = $1;
            $hash->{$u} = $p;
            $self->_debug("Permissions: $u => $p");
        }
    }
    return $hash;
}

sub listrights {
    my ( $self, $target, $user ) = @_;
    $target ||= $self->Folder;
    $target = $self->Massage($target);

    $user ||= $self->User;
    $user =~ s/^"(.*)"$/$1/;
    $user =~ s/"/\\"/g;

    $self->_imap_command(qq(LISTRIGHTS $target "$user"))
      or return undef;

    my $resp = first { /^\* LISTRIGHTS/ } $self->History;
    my @rights = split /\s/, $resp;
    my $rights = join '', @rights[ 4 .. $#rights ];
    $rights =~ s/"//g;
    return wantarray ? split( //, $rights ) : $rights;
}

sub select {
    my ( $self, $target ) = @_;
    defined $target or return undef;

    my $qqtarget = $self->Massage($target);
    my $old      = $self->Folder;

    $self->_imap_command("SELECT $qqtarget")
      or return undef;

    $self->State(Selected);
    $self->Folder($target);
    return $old || $self;    # ??$self??
}

sub message_string {
    my ( $self, $msg ) = @_;

    return undef unless defined $self->imap4rev1;
    my $peek = $self->Peek      ? '.PEEK'        : '';
    my $cmd  = $self->imap4rev1 ? "BODY$peek\[]" : "RFC822$peek";

    $self->fetch( $msg, $cmd )
      or return undef;

    my $string = $self->_transaction_literals;

    unless ( $self->Ignoresizeerrors ) {    # Check size with expected size
        my $expected_size = $self->size($msg);
        return undef unless defined $expected_size;

        # RFC822.SIZE may be wrong, see RFC2683 3.4.5 "RFC822.SIZE"
        if ( length($string) != $expected_size ) {
            $self->LastError( "message_string() "
                  . "expected $expected_size bytes but received "
                  . length($string)
                  . " you may need the IgnoreSizeErrors option" );
            return undef;
        }
    }

    return $string;
}

sub bodypart_string {
    my ( $self, $msg, $partno, $bytes, $offset ) = @_;

    unless ( $self->imap4rev1 ) {
        $self->LastError( "Unable to get body part; server "
              . $self->Server
              . " does not support IMAP4REV1" )
          unless $self->LastError;
        return undef;
    }

    $offset ||= 0;
    my $cmd = "BODY"
      . ( $self->Peek ? '.PEEK' : '' )
      . "[$partno]"
      . ( $bytes ? "<$offset.$bytes>" : '' );

    $self->fetch( $msg, $cmd )
      or return undef;

    $self->_transaction_literals;
}

sub message_to_file {
    my $self = shift;
    my $fh   = shift;
    my $msgs = join ',', @_;

    my $handle;
    if ( ref $fh ) { $handle = $fh }
    else {
        $handle = IO::File->new(">>$fh");
        unless ( defined($handle) ) {
            $self->LastError("Unable to open $fh: $!");
            return undef;
        }
        binmode $handle;    # For those of you who need something like this...
    }

    my $clear = $self->Clear;
    $self->Clear($clear)
      if $self->Count >= $clear && $clear > 0;

    return undef unless defined $self->imap4rev1;
    my $peek = $self->Peek      ? '.PEEK'        : '';
    my $cmd  = $self->imap4rev1 ? "BODY$peek\[]" : "RFC822$peek";

    my $uid    = $self->Uid ? "UID " : "";
    my $trans  = $self->Count( $self->Count + 1 );
    my $string = "$trans ${uid}FETCH $msgs $cmd";

    $self->_record( $trans, [ 0, "INPUT", $string ] );

    my $feedback = $self->_send_line($string);
    unless ($feedback) {
        $self->LastError( "Error sending '$string': " . $self->LastError );
        return undef;
    }

    # look for "<tag> (OK|BAD|NO)"
    my $code = $self->_get_response( { outref => $handle }, $trans )
      or return undef;

    return $code eq 'OK' ? $self : undef;
}

sub message_uid {
    my ( $self, $msg ) = @_;

    my $ref = $self->fetch( $msg, "UID" ) or return undef;
    foreach (@$ref) {
        return $1 if m/\(UID\s+(\d+)\s*\)$CR?$/o;
    }
    return undef;
}

#???? this code is very clumsy, and currently probably broken.
#  Why not use a pipe???
#  Is a quadratic slowdown not much simpler and better???
#  Shouldn't the slowdowns extend over multiple messages?
#  --> create clean read and write methods

sub migrate {
    my ( $self, $peer, $msgs, $folder ) = @_;
    my $toSock = $peer->Socket, my $fromSock = $self->Socket;
    my $bufferSize = $self->Buffer || 4096;

    local $SIG{PIPE} = 'IGNORE';    # avoid SIGPIPE on syswrite, handle as error

    unless ( $peer and $peer->IsConnected ) {
        $self->LastError( "Invalid or unconnected peer "
              . ref($self)
              . " object used as target for migrate. $@" );
        return undef;
    }

    unless ($folder) {
        unless ( $folder = $self->Folder ) {
            $self->LastError("No folder selected on source mailbox.");
            return undef;
        }

        unless ( $peer->exists($folder) || $peer->create($folder) ) {
            $self->LastError( "Unable to create folder '$folder' on target "
                  . "mailbox: "
                  . $peer->LastError );
            return undef;
        }
    }

    defined $msgs or $msgs = "ALL";
    $msgs = $self->search("ALL")
      if uc $msgs eq 'ALL';
    return undef unless defined $msgs;

    my $range = $self->Range($msgs);
    my $clear = $self->Clear;

    $self->_debug("Migrating the following msgs from $folder: $range");
  MSG:
    foreach my $mid ( $range->unfold ) {
        $self->_debug("Migrating message $mid in folder $folder");

        my $leftSoFar = my $size = $self->size($mid);
        return undef unless defined $size;

        # fetch internaldate and flags of original message:
        my $intDate = $self->internaldate($mid);
        return undef unless defined $intDate;

        my @flags = grep !/\\Recent/i, $self->flags($mid);
        my $flags = join ' ', $peer->supported_flags(@flags);

        # set up transaction numbers for from and to connections:
        my $trans  = $self->Count( $self->Count + 1 );
        my $ptrans = $peer->Count( $peer->Count + 1 );

        # If msg size is less than buffersize then do whole msg in one
        # transaction:
        if ( $size <= $bufferSize ) {
            my $new_mid =
              $peer->append_string( $folder, $self->message_string($mid),
                $flags, $intDate );

            unless ( defined $new_mid ) {
                $self->LastError( "Unable to append to $folder "
                      . "on target mailbox. "
                      . $peer->LastError );
                return undef;
            }

            $self->_debug( "Copied message $mid in folder $folder to "
                  . $peer->User . '@'
                  . $peer->Server
                  . ". New message UID is $new_mid" )
              if $self->Debug;

            $peer->_debug( "Copied message $mid in folder $folder from "
                  . $self->User . '@'
                  . $self->Server
                  . ". New message UID is $new_mid" )
              if $peer->Debug;

            next MSG;
        }

        # otherwise break it up into digestible pieces:
        return undef unless defined $self->imap4rev1;
        my ( $cmd, $extract_size );
        if ( $self->imap4rev1 ) {
            $cmd = $self->Peek ? 'BODY.PEEK[]' : 'BODY[]';
            $extract_size = sub { $_[0] =~ /\(.*BODY\[\]<\d+> \{(\d+)\}/i; $1 };
        }
        else {
            $cmd = $self->Peek ? 'RFC822.PEEK' : 'RFC822';
            $extract_size = sub { $_[0] =~ /\(RFC822\[\]<\d+> \{(\d+)\}/i; $1 };
        }

        # Now let's warn the peer that there's a message coming:
        my $pstring =
            "$ptrans APPEND "
          . $self->Massage($folder)
          . ( length $flags ? " ($flags)" : '' )
          . qq( "$intDate" {$size});

        $self->_debug("About to issue APPEND command to peer for msg $mid");

        $peer->_record( $ptrans, [ 0, "INPUT", $pstring ] );
        unless ( $peer->_send_line($pstring) ) {
            $self->LastError( "Error sending '$pstring': " . $self->LastError );
            return undef;
        }

        # Get the "+ Go ahead" response:
        my $code;
        until ( defined $code ) {
            my $readSoFar  = 0;
            my $fromBuffer = '';
            $readSoFar += sysread( $toSock, $fromBuffer, 1, $readSoFar ) || 0
              until $fromBuffer =~ /$CRLF/o;

            $code =
                $fromBuffer =~ /^\+/                  ? 'OK'
              : $fromBuffer =~ /^\d+\s+(BAD|NO|OK)\b/ ? $1
              :                                         undef;

            $peer->_debug("$folder: received $fromBuffer from server");

            if ( $fromBuffer =~ /^(\*\s+BYE.*?)$CR?$LF/oi ) {
                $self->State(Unconnected);
                $self->LastError($1);
                return undef;
            }

            # ... and log it in the history buffers
            $self->_record(
                $trans,
                [
                    0,
                    "OUTPUT",
"Mail::IMAPClient migrating message $mid to $peer->User\@$peer->Server"
                ]
            );
            $peer->_record( $ptrans, [ 0, "OUTPUT", $fromBuffer ] );
        }

        if ( $code ne 'OK' ) {
            $self->_debug("Error writing to target host: $@");
            next MIGMSG;
        }

        # Here is where we start sticking in UID if that parameter
        # is turned on:
        my $string = ( $self->Uid ? "UID " : "" ) . "FETCH $mid $cmd";

        # Clean up history buffer if necessary:
        $self->Clear($clear)
          if $self->Count >= $clear && $clear > 0;

        # position will tell us how far from beginning of msg the
        # next IMAP FETCH should start (1st time start at offset zero):
        my $position   = 0;
        my $chunkCount = 0;
        my $readSoFar  = 0;
        while ( $leftSoFar > 0 ) {
            my $take = min $leftSoFar, $bufferSize;
            my $newstring = "$trans $string<$position.$take>";

            $self->_record( $trans, [ 0, "INPUT", $newstring ] );
            $self->_debug("Issuing migration command: $newstring");

            unless ( $self->_send_line($newstring) ) {
                $self->LastError( "Error sending '$newstring' to source IMAP: "
                      . $self->LastError );
                return undef;
            }

            my $chunk;
            my $fromBuffer = "";
            until ( $chunk = $extract_size->($fromBuffer) ) {
                $fromBuffer = '';
                sysread( $fromSock, $fromBuffer, 1, length $fromBuffer )
                  until $fromBuffer =~ /$CRLF$/o;

                $self->_record( $trans, [ 0, "OUTPUT", $fromBuffer ] );

                if ( $fromBuffer =~ /^$trans\s+(?:NO|BAD)/ ) {
                    $self->LastError($fromBuffer);
                    next MIGMSG;
                }
                elsif ( $fromBuffer =~ /^$trans\s+OK/ ) {
                    $self->LastError( "Unexpected good return code "
                          . "from source host: $fromBuffer" );
                    next MIGMSG;
                }
            }

            $fromBuffer = "";
            while ( $readSoFar < $chunk ) {
                $readSoFar +=
                  sysread( $fromSock, $fromBuffer, $chunk - $readSoFar,
                    $readSoFar )
                  || 0;
            }

            my $wroteSoFar = 0;
            my $temperrs   = 0;
            my $waittime   = .02;
            my $maxwrite   = 0;
            my $maxagain   = $self->Maxtemperrors || 10;
            undef $maxagain if $maxagain eq 'unlimited';
            my @previous_writes;

            while ( $wroteSoFar < $chunk ) {
                while ( $wroteSoFar < $readSoFar ) {
                    my $ret =
                      syswrite( $toSock, $fromBuffer, $chunk - $wroteSoFar,
                        $wroteSoFar );

                    if ( defined $ret ) {
                        $wroteSoFar += $ret;
                        $maxwrite = max $maxwrite, $ret;
                        $temperrs = 0;
                    }

                    if ( $! == EPIPE or $! == ECONNRESET ) {
                        $self->State(Unconnected);
                        $self->LastError("Write failed '$!'");
                        return undef;
                    }

                    if ( $! == EAGAIN || $ret == 0 ) {
                        if ( defined $maxagain && $temperrs++ > $maxagain ) {
                            $self->LastError("Persistent error '$!'");
                            return undef;
                        }

                        $waittime = $self->_optimal_sleep( $maxwrite, $waittime,
                            \@previous_writes );
                        next;
                    }

                    $self->State(Unconnected)
                      if ( $! == EPIPE or $! == ECONNRESET );
                    $self->LastError("Write failed '$!'");
                    return;    # no luck
                }

                $peer->_debug(
                    "Chunk $chunkCount: wrote $wroteSoFar (of $chunk)");
            }
        }

        $position += $readSoFar;
        $leftSoFar -= $readSoFar;
        my $fromBuffer = "";

        # Finish up reading the server fetch response from the source system:
        # look for "<trans> (OK|BAD|NO)"
        $self->_debug("Reading from source: expecting 'OK' response");
        $code = $self->_get_response($trans) or return undef;
        return undef unless $code eq 'OK';

        # Now let's send a CRLF to the peer to signal end of APPEND cmd:
        unless ( $peer->_send_bytes( \$CRLF ) ) {
            $self->LastError( "Error appending CRLF: " . $self->LastError );
            return undef;
        }

        # Finally, let's get the new message's UID from the peer:
        # look for "<tag> (OK|BAD|NO)"
        $peer->_debug("Reading from target: expect new uid in response");
        $code = $peer->_get_response($ptrans) or return undef;

        my $new_mid = "unknown";
        if ( $code eq 'OK' ) {
            my $data = join '', $self->Results;

            # look for something like return size or self if no size found:
            # <tag> OK [APPENDUID <uid> <size>] APPEND completed
            my $ret = $data =~ m#\s+(\d+)\]# ? $1 : undef;
            $new_mid = $ret;
        }

        if ( $self->Debug ) {
            $self->_debug( "Copied message $mid in folder $folder to "
                  . $peer->User . '@'
                  . $peer->Server
                  . ". New Message UID is $new_mid" );

            $peer->_debug( "Copied message $mid in folder $folder from "
                  . $self->User . '@'
                  . $self->Server
                  . ". New Message UID is $new_mid" );
        }
    }

    return $self;
}

# Optimization of wait time between syswrite calls only runs if syscalls
# run too fast and fill the buffer causing "EAGAIN: Resource Temp. Unavail"
# errors. The premise is that $maxwrite will be approx. the same as the
# smallest buffer between the sending and receiving side. Waiting time
# between syscalls should ideally be exactly as long as it takes the
# receiving side to empty that buffer, minus a little bit to prevent it
# from emptying completely and wasting time in the select call.

sub _optimal_sleep($$$) {
    my ( $self, $maxwrite, $waittime, $last5writes ) = @_;

    push @$last5writes, $waittime;
    shift @$last5writes if @$last5writes > 5;

    my $bufferavail = ( sum @$last5writes ) / @$last5writes;

    if ( $bufferavail < .4 * $maxwrite ) {

        # Buffer is staying pretty full; we should increase the wait
        # period to reduce transmission overhead/number of packets sent
        $waittime *= 1.3;
    }
    elsif ( $bufferavail > .9 * $maxwrite ) {

        # Buffer is nearly or totally empty; we're wasting time in select
        # call that could be used to send data, so reduce the wait period
        $waittime *= .5;
    }

    CORE::select( undef, undef, undef, $waittime );
    $waittime;
}

sub body_string {
    my ( $self, $msg ) = @_;
    my $ref =
      $self->fetch( $msg, "BODY" . ( $self->Peek ? ".PEEK" : "" ) . "[TEXT]" )
      or return undef;

    my $string = join '', map { $_->[DATA] }
      grep { $self->_is_literal($_) } @$ref;

    return $string
      if $string;

    my $head;
    while ( $head = shift @$ref ) {
        $self->_debug("body_string: head = '$head'");

        last
          if $head =~
              /(?:.*FETCH .*\(.*BODY\[TEXT\])|(?:^\d+ BAD )|(?:^\d NO )/i;
    }

    unless (@$ref) {
        $self->LastError(
            "Unable to parse server response from " . $self->LastIMAPCommand );
        return undef;
    }

    my $popped;
    $popped = pop @$ref    # (-: vi
      until ( $popped && $popped =~ /\)$CRLF$/o )    # (-: vi
      || !grep /\)$CRLF$/o, @$ref;

    if ( $head =~ /BODY\[TEXT\]\s*$/i ) {            # Next line is a literal
        $string .= shift @$ref while @$ref;
        $self->_debug("String is now $string")
          if $self->Debug;
    }

    $string;
}

sub examine {
    my ( $self, $target ) = @_;
    defined $target or return undef;

    $self->_imap_command( 'EXAMINE ' . $self->Massage($target) )
      or return undef;

    my $old = $self->Folder;
    $self->Folder($target);
    $self->State(Selected);
    $old || $self;
}

sub idle {
    my $self  = shift;
    my $good  = '+';
    my $count = $self->Count + 1;
    $self->_imap_command( "IDLE", $good ) ? $count : undef;
}

sub done {
    my $self = shift;
    my $count = shift || $self->Count;
    $self->_imap_command( { addtag => 0, tag => $count }, "DONE" )
      or return undef;
    return $self->Results;
}

sub tag_and_run {
    my ( $self, $string, $good ) = @_;
    $self->_imap_command( $string, $good ) or return undef;
    return $self->Results;
}

sub reconnect {
    my $self = shift;

    if ( $self->IsAuthenticated ) {
        $self->_debug("reconnect called but already authenticated");
        return $self;
    }

    my $einfo = $self->LastError || "";
    $self->_debug( "reconnecting to ", $self->Server, ", last error: $einfo" );

    # reconnect and select appropriate folder
    $self->connect or return undef;

    return ( defined $self->Folder ) ? $self->select( $self->Folder ) : $self;
}

# wrapper for _imap_command_do to enable retrying on lost connections
sub _imap_command {
    my $self = shift;

    my $tries = 0;
    my $retry = $self->Reconnectretry || 0;
    my ( $rc, @err );

    # LastError (if set) will be overwritten masking any earlier errors
    while ( $tries++ <= $retry ) {

        # do command on the first try or if Connected (reconnect ongoing)
        if ( $tries == 1 or $self->IsConnected ) {
            $rc = $self->_imap_command_do(@_);
            push( @err, $self->LastError ) if $self->LastError;
        }

        if ( !defined($rc) and $retry and $self->IsUnconnected ) {
            last
              unless (
                   $! == EPIPE
                or $! == ECONNRESET
                or $self->LastError =~ /(?:timeout|error) waiting\b/
                or $self->LastError =~ /(?:socket closed|\* BYE)\b/

                # BUG? reconnect if caller ignored/missed earlier errors?
                # or $self->LastError =~ /NO not connected/
              );
            if ( $self->reconnect ) {
                $self->_debug("reconnect successful on try #$tries");
            }
            else {
                $self->_debug("reconnect failed on try #$tries");
                push( @err, $self->LastError ) if $self->LastError;
            }
        }
        else {
            last;
        }
    }

    unless ($rc) {
        my ( %seen, @keep, @info );

        foreach my $str (@err) {
            my ( $sz, $len ) = ( 96, length($str) );
            $str =~ s/$CR?$LF$/\\n/omg;
            if ( !$self->Debug and $len > $sz * 2 ) {
                my $beg = substr( $str, 0,    $sz );
                my $end = substr( $str, -$sz, $sz );
                $str = $beg . "..." . $end;
            }
            next if $seen{$str}++;
            push( @keep, $str );
        }
        foreach my $msg (@keep) {
            push( @info, $msg . ( $seen{$msg} > 1 ? " ($seen{$msg}x)" : "" ) );
        }
        $self->LastError( join( "; ", @info ) );
    }

    return $rc;
}

# _imap_command_do runs a command, inserting a tag and CRLF as requested
# options:
#   addcrlf => 0|1  - suppress adding CRLF to $string
#   addtag  => 0|1  - suppress adding $tag to $string
#   tag     => $tag - use this $tag instead of incrementing count
sub _imap_command_do {
    my $self   = shift;
    my $opt    = ref( $_[0] ) eq "HASH" ? shift : {};
    my $string = shift or return undef;
    my $good   = shift;

    $opt->{addcrlf} = 1 unless exists $opt->{addcrlf};
    $opt->{addtag}  = 1 unless exists $opt->{addtag};

    # reset error in case the last error was non-fatal but never cleared
    if ( $self->LastError ) {

        #DEBUG $self->_debug( "Reset LastError: " . $self->LastError );
        $self->LastError(undef);
    }

    my $clear = $self->Clear;
    $self->Clear($clear)
      if $self->Count >= $clear && $clear > 0;

    my $count = $self->Count( $self->Count + 1 );
    my $tag = $opt->{tag} || $count;
    $string = "$tag $string" if $opt->{addtag};

    # for APPEND (append_string) only log first line of command
    my $logstr = ( $string =~ /^($tag\s+APPEND\s+.*?)$CR?$LF/ ) ? $1 : $string;

    # BUG? use $self->_next_index($tag) ? or 0 ???
    # $self->_record($tag, [$self->_next_index($tag), "INPUT", $logstr] );
    $self->_record( $count, [ 0, "INPUT", $logstr ] );

    # $suppress (adding CRLF) set to 0 if $opt->{addcrlf} is TRUE
    unless ( $self->_send_line( $string, $opt->{addcrlf} ? 0 : 1 ) ) {
        $self->LastError( "Error sending '$logstr': " . $self->LastError );
        return undef;
    }

    # look for "<tag> (OK|BAD|NO|$good)" (or "+..." if $good is '+')
    my $code = $self->_get_response( $tag, $good ) or return undef;

    if ( $code eq 'OK' ) {
        return $self;
    }
    elsif ( $good and $code eq $good ) {
        return $self;
    }
    else {
        return undef;
    }
}

# _get_response get IMAP response optionally send data somewhere
# options:
#   outref => GLOB|CODE - reference to send output to (see _read_line)
sub _get_response {
    my $self = shift;
    my $opt  = ref( $_[0] ) eq "HASH" ? shift : {};
    my $tag  = shift;
    my $good = shift;

    # tag can be a ref (compiled regex) or we quote it or default to \S+
    my $qtag = ref($tag) ? $tag : defined($tag) ? quotemeta($tag) : qr/\S+/;
    my $qgood = ref($good) ? $good : defined($good) ? quotemeta($good) : undef;
    my @readopt = defined( $opt->{outref} ) ? ( $opt->{outref} ) : ();

    my ( $count, $out, $code, $byemsg ) = ( $self->Count, [], undef, undef );
    until ($code) {
        my $output = $self->_read_line(@readopt) or return undef;
        $out = $output;    # keep last response just in case

        # not using last on first match? paranoia or right thing?
        # only uc() when match is not on case where $tag|$good is a ref()
        foreach my $o (@$output) {
            $self->_record( $count, $o );
            $self->_is_output($o) or next;

            my $data = $o->[DATA];
            if ( $good and $good ne '+' and $data =~ /^$qtag\s+($qgood)/i ) {
                $code = $1;
                $code = uc($code) unless ref($good);
            }
            elsif ( $good and $good eq '+' and $data =~ /^$qgood/ ) {
                $code = $good;
            }
            elsif ( $tag eq '+' and $data =~ /^$qtag/ ) {
                $code = $tag;
            }
            elsif ( $data =~ /^$qtag\s+(OK|BAD|NO)\b/i ) {
                $code = uc($1);
                $self->LastError($data) unless ( $code eq 'OK' );
            }
            elsif ( $data =~ /^\*\s+(BYE)\b/i ) {
                $code   = uc($1);
                $byemsg = $data;
            }
        }
    }

    if ($code) {
        $code = uc($code) unless ( $good and $code eq $good );

        # on a successful LOGOUT $code is OK not BYE
        if ( $code eq 'BYE' ) {
            $self->State(Unconnected);
            $self->LastError($byemsg) if $byemsg;
        }
    }
    elsif ( !$self->LastError ) {
        my $info = "unexpected response: " . join( " ", @$out );
        $self->LastError($info);
    }

    return $code;
}

sub _imap_uid_command {
    my ( $self, $cmd ) = ( shift, shift );
    my $args = @_ ? join( " ", '', @_ ) : '';
    my $uid = $self->Uid ? 'UID ' : '';
    $self->_imap_command("$uid$cmd$args");
}

sub run {
    my $self = shift;
    my $string = shift or return undef;

    my $tag = $string =~ /^(\S+) / ? $1 : undef;
    unless ($tag) {
        $self->LastError("No tag found in string passed to run(): $string");
        return undef;
    }

    $self->_imap_command( { addtag => 0, addcrlf => 0, tag => $tag }, $string )
      or return undef;

    $self->{History}{$tag} = $self->{History}{ $self->Count }
      unless $tag eq $self->Count;

    return $self->Results;
}

# _record saves the conversation into the History structure:
sub _record {
    my ( $self, $count, $array ) = @_;
    if ( $array->[DATA] =~ /^\d+ LOGIN/i && !$self->Showcredentials ) {
        $array->[DATA] =~ s/LOGIN.*/LOGIN XXXXXXXX XXXXXXXX/i;
    }

    push @{ $self->{History}{$count} }, $array;
}

# _send_line handles literal data and supports the Prewritemethod
sub _send_line {
    my ( $self, $string, $suppress ) = ( shift, shift, shift );

    $string =~ s/$CR?$LF?$/$CRLF/o
      unless $suppress;

    # handle case where string contains a literal
    if ( $string =~ s/^([^$LF\{]*\{\d+\}$CRLF)(?=.)//o ) {
        my $first = $1;
        $self->_debug("Sending literal: $first\tthen: $string");
        $self->_send_line($first) or return undef;

        # look for "<anything> OK|NO|BAD" or "+..."
        my $code = $self->_get_response( qr(\S+), '+' ) or return undef;
        return undef unless $code eq '+';
    }

    # non-literal part continues...
    unless ( $self->IsConnected ) {
        $self->LastError("NO not connected");
        return undef;
    }

    if ( my $prew = $self->Prewritemethod ) {
        $string = $prew->( $self, $string );
    }

    $self->_debug("Sending: $string");
    $self->_send_bytes( \$string );
}

sub _send_bytes($) {
    my ( $self, $byteref ) = @_;
    my ( $total, $temperrs, $maxwrite ) = ( 0, 0, 0 );
    my $waittime = .02;
    my @previous_writes;

    my $maxagain = $self->Maxtemperrors || 10;
    undef $maxagain if $maxagain eq 'unlimited';

    local $SIG{PIPE} = 'IGNORE';    # handle SIGPIPE as normal error

    while ( $total < length $$byteref ) {
        my $written =
          syswrite( $self->Socket, $$byteref, length($$byteref) - $total,
            $total );

        if ( defined $written ) {
            $temperrs = 0;
            $total += $written;
            next;
        }

        if ( $! == EAGAIN ) {
            if ( defined $maxagain && $temperrs++ > $maxagain ) {
                $self->LastError("Persistent error '$!'");
                return undef;
            }

            $waittime =
              $self->_optimal_sleep( $maxwrite, $waittime, \@previous_writes );
            next;
        }

        # Unconnected might be apropos for more than just these?
        my $emsg = $! ? "$!" : "no error caught";
        $self->State(Unconnected) if ( $! == EPIPE or $! == ECONNRESET );
        $self->LastError("Write failed '$emsg'");

        return undef;    # no luck
    }

    $self->_debug("Sent $total bytes");
    return $total;
}

# _read_line: read one line from the socket

# It is also re-implemented in: message_to_file
#
# $output = $self->_read_line($literal_callback, $output_callback)
#    Both input arguments are optional, but if supplied must either
#    be a filehandle, coderef, or undef.
#
#    Returned argument is a reference to an array of arrays, ie:
#    $output = [
#            [ $index, 'OUTPUT'|'LITERAL', $output_line ] ,
#            [ $index, 'OUTPUT'|'LITERAL', $output_line ] ,
#            ...     # etc,
#    ];

sub _read_line {
    my ( $self, $literal_callback, $output_callback ) = @_;

    my $socket = $self->Socket;
    unless ( $self->IsConnected && $socket ) {
        $self->LastError("NO not connected");
        return undef;
    }

    my $iBuffer = "";
    my $oBuffer = [];
    my $index   = $self->_next_index;
    my $timeout = $self->Timeout;
    my $readlen = $self->{Buffer} || 4096;

    until (
        @$oBuffer    # there's stuff in output buffer:
          && $oBuffer->[-1][TYPE] eq 'OUTPUT'    # that thing is an output line:
          && $oBuffer->[-1][DATA] =~
          /$CR?$LF$/o            # the last thing there has cr-lf:
          && !length $iBuffer    # and the input buffer has been MT'ed:
      )
    {
        my $transno = $self->Transaction;

        if ($timeout) {
            my $rc = _read_more( $socket, $timeout );
            unless ( $rc > 0 ) {
                my $msg =
                    ( $rc ? "error" : "timeout" )
                  . " waiting ${timeout}s for data from server"
                  . ( $! ? ": $!" : "" );
                $self->LastError($msg);
                $self->_record(
                    $transno,
                    [
                        $self->_next_index($transno), "ERROR",
                        "$transno * NO $msg"
                    ]
                );
                $self->_disconnect;    # BUG: can not handle timeouts gracefully
                return undef;
            }
        }

        my $emsg;
        my $ret =
          $self->_sysread( $socket, \$iBuffer, $readlen, length $iBuffer );
        if ( $timeout && !defined $ret ) {
            $emsg = "error while reading data from server: $!";
            $self->State(Unconnected) if ( $! == ECONNRESET );
        }

        if ( defined $ret && $ret == 0 ) {    # Caught EOF...
            $emsg = "socket closed while reading data from server";
            $self->State(Unconnected);
        }

        # save errors and return
        if ($emsg) {
            $self->LastError($emsg);
            $self->_record(
                $transno,
                [
                    $self->_next_index($transno), "ERROR", "$transno * NO $emsg"
                ]
            );
            return undef;
        }

        while ( $iBuffer =~ s/^(.*?$CR?$LF)//o )    # consume line
        {
            my $current_line = $1;
            if ( $current_line !~ s/\s*\{(\d+)\}$CR?$LF$//o ) {
                push @$oBuffer, [ $index++, 'OUTPUT', $current_line ];
                next;
            }

            push @$oBuffer, [ $index++, 'OUTPUT', $current_line ];

            ## handle LITERAL
            # BLAH BLAH {nnn}$CRLF
            # [nnn bytes of literally transmitted stuff]
            # [part of line that follows literal data]$CRLF

            my $expected_size = $1;

            $self->_debug( "LITERAL: received literal in line "
                  . "$current_line of length $expected_size; attempting to "
                  . "retrieve from the "
                  . length($iBuffer)
                  . " bytes in: $iBuffer<END_OF_iBuffer>" );

            my $litstring;
            if ( length $iBuffer >= $expected_size ) {

                # already received all data
                $litstring = substr $iBuffer, 0, $expected_size, '';
            }
            else {    # literal data still to arrive
                $litstring = $iBuffer;
                $iBuffer   = '';

                while ( $expected_size > length $litstring ) {
                    if ($timeout) {
                        my $rc = _read_more( $socket, $timeout );
                        unless ( $rc > 0 ) {
                            my $msg =
                                ( $rc ? "error" : "timeout" )
                              . " waiting ${timeout}s for literal data from server"
                              . ( $! ? ": $!" : "" );
                            $self->LastError($msg);
                            $self->_record(
                                $transno,
                                [
                                    $self->_next_index($transno), "ERROR",
                                    "$transno * NO $msg"
                                ]
                            );
                            $self->_disconnect;   # BUG: can not handle timeouts
                            return undef;
                        }
                    }
                    else {                        # 25 ms before retry
                        CORE::select( undef, undef, undef, 0.025 );
                    }

                    my $ret = $self->_sysread(
                        $socket, \$litstring,
                        $expected_size - length $litstring,
                        length $litstring
                    );

                    if ( $timeout && !defined $ret ) {
                        $emsg = "error while reading data from server: $!";
                        $self->State(Unconnected) if ( $! == ECONNRESET );
                    }

                    # EOF: note IO::Socket::SSL does not support eof()
                    if ( defined $ret && $ret == 0 ) {
                        $emsg = "socket closed while reading data from server";
                        $self->State(Unconnected);
                    }

                    $self->_debug( "Received ret="
                          . ( defined($ret) ? "$ret " : "<undef> " )
                          . length($litstring)
                          . " of $expected_size" );

                    # save errors and return
                    if ($emsg) {
                        $self->LastError($emsg);
                        $self->_record(
                            $transno,
                            [
                                $self->_next_index($transno), "ERROR",
                                "$transno * NO $emsg"
                            ]
                        );
                        $litstring = "" unless defined $litstring;
                        $self->_debug( "ERROR while processing LITERAL, "
                              . " buffer=\n"
                              . $litstring
                              . "<END>\n" );
                        return undef;
                    }
                }
            }

            if ( !$literal_callback ) { ; }
            elsif ( UNIVERSAL::isa( $literal_callback, 'GLOB' ) ) {
                print $literal_callback $litstring;
                $litstring = "";
            }
            elsif ( UNIVERSAL::isa( $literal_callback, 'CODE' ) ) {
                $literal_callback->($litstring)
                  if defined $litstring;
            }
            else {
                $self->LastError( "'$literal_callback' is an "
                      . "invalid callback; must be a filehandle or CODE" );
            }

            push @$oBuffer, [ $index++, 'LITERAL', $litstring ];
        }
    }

    $self->_debug( "Read: " . join "", map { "\t" . $_->[DATA] } @$oBuffer );
    @$oBuffer ? $oBuffer : undef;
}

sub _sysread($$$$) {
    my ( $self, $fh, $buf, $len, $off ) = @_;
    my $rm = $self->Readmethod;
    $rm ? $rm->(@_) : sysread( $fh, $$buf, $len, $off );
}

sub _read_more($$) {
    my ( $socket, $timeout ) = @_;

    # IO::Socket::SSL buffers some data internally, so there might be some
    # data available from the previous sysread of which the file-handle
    # (used by select()) doesn't know of.
    return 1 if $socket->isa("IO::Socket::SSL") && $socket->pending;

    my $rvec = '';
    vec( $rvec, fileno($socket), 1 ) = 1;
    return CORE::select( $rvec, undef, $rvec, $timeout );
}

sub _trans_index() {
    sort { $a <=> $b } keys %{ $_[0]->{History} };
}

# all default to last transaction
sub _transaction(;$) {
    @{ $_[0]->{History}{ $_[1] || $_[0]->Transaction } || [] };
}

sub _trans_data(;$) {
    map { $_->[DATA] } $_[0]->_transaction( $_[1] );
}

sub Report {
    my $self = shift;
    map { $self->_trans_data($_) } $self->_trans_index;
}

sub LastIMAPCommand(;$) {
    my ( $self, $trans ) = @_;
    my $msg = ( $self->_transaction($trans) )[0];
    $msg ? $msg->[DATA] : undef;
}

sub History(;$) {
    my ( $self, $trans ) = @_;
    my ( $cmd,  @a )     = $self->_trans_data($trans);
    return wantarray ? @a : \@a;
}

sub Results(;$) {
    my ( $self, $trans ) = @_;
    my @a = $self->_trans_data($trans);
    return wantarray ? @a : \@a;
}

# Don't know what it does, but used a few times.
sub _transaction_literals() {
    my $self = shift;
    join '', map { $_->[DATA] }
      grep { $self->_is_literal($_) } $self->_transaction;
}

sub Escaped_results {
    my ( $self, $trans ) = @_;
    my @a;
    foreach my $line ( grep defined, $self->Results($trans) ) {
        if ( $self->_is_literal($line) ) {
            $line->[DATA] =~ s/([\\\(\)"$CRLF])/\\$1/og;
            push @a, qq("$line->[DATA]");
        }
        else { push @a, $line->[DATA] }
    }

    shift @a;    # remove cmd
    return wantarray ? @a : \@a;
}

sub Unescape {
    my $whatever = $_[1];
    $whatever =~ s/\\([\\\(\)"$CRLF])/$1/og;
    $whatever;
}

sub logout {
    my $self = shift;
    $self->_imap_command("LOGOUT");
    $self->_disconnect;
}

sub _disconnect {
    my $self = shift;

    delete $self->{Folders};
    delete $self->{_IMAP4REV1};
    $self->State(Unconnected);
    if ( my $sock = delete $self->{Socket} ) {
        eval { $sock->close };
    }
    $self;
}

# LIST or LSUB Response
#   Contents: name attributes, hierarchy delimiter, name
#   Example: * LIST (\Noselect) "/" ~/Mail/foo
# NOTE: in _list_response_preprocess we append literal data so we need
# to be liberal about our matching of folder name data
sub _list_or_lsub_response_parse {
    my ( $self, $resp ) = @_;

    return undef unless defined $resp;
    my %info;

    $resp =~ s/\015?\012$//;
    if (
        $resp =~ / ^\* \s+ (?:LIST|LSUB) \s+   # * LIST or LSUB
                 \( ([^\)]*) \)          \s+   # (attrs)
           (?:   \" ([^"]*)  \" | NIL  ) \s    # "delimiter" or NIL
           (?:\s*\" (.*)     \" | (.*) )       # "name" or name
         /ix
      )
    {
        @info{qw(attrs delim name)} =
          ( [ split( / /, $1 ) ], $2, defined($3) ? $self->Unescape($3) : $4 );
    }
    return wantarray ? %info : \%info;
}

# handle listeral data returned in list/lsub responses
# some example responses:
# * LIST () "/" "My Folder"    # nothing to do here...
# * LIST () "/" {9}            # the {9} is already removed by _read_line()
# Special %                    # we append this to the previous line
sub _list_response_preprocess {
    my ( $self, $data ) = @_;
    return undef unless defined $data;

    for ( my $m = 0 ; $m < @$data ; $m++ ) {
        if ( $data->[$m] && $data->[$m] !~ /$CR?$LF$/o ) {
            $self->_debug("concatenating '$data->[$m]' and '$data->[$m+1]'");
            $data->[$m] .= " " . $data->[ $m + 1 ];
            splice @$data, $m + 1, 1;
        }
    }
    return $data;
}

sub exists {
    my ( $self, $folder ) = @_;
    $self->status($folder) ? $self : undef;
}

# Updated to handle embedded literal strings
sub get_bodystructure {
    my ( $self, $msg ) = @_;
    unless ( eval { require Mail::IMAPClient::BodyStructure; } ) {
        $self->LastError("Unable to use get_bodystructure: $@");
        return undef;
    }

    my $out = $self->fetch( $msg, "BODYSTRUCTURE" ) or return undef;

    my $bs = "";
    my $output = first { /BODYSTRUCTURE\s+\(/i } @$out;    # Wee! ;-)
    if ( $output =~ /$CRLF$/o ) {
        $bs = eval { Mail::IMAPClient::BodyStructure->new($output) };
    }
    else {
        $self->_debug("get_bodystructure: reassembling original response");
        my $started = 0;
        my $output  = '';
        foreach my $o ( $self->_transaction ) {
            next unless $self->_is_output_or_literal($o);
            $started++ if $o->[DATA] =~ /BODYSTRUCTURE \(/i;
            ;    # Hi, vi! ;-)
            $started or next;

            if ( length $output && $self->_is_literal($o) ) {
                my $data = $o->[DATA];
                $data =~ s/"/\\"/g;
                $data =~ s/\(/\\\(/g;
                $data =~ s/\)/\\\)/g;
                $output .= qq("$data");
            }
            else { $output .= $o->[DATA] }

            $self->_debug("get_bodystructure: reassembled output=$output<END>");
        }
        eval { $bs = Mail::IMAPClient::BodyStructure->new($output) };
    }

    $self->_debug(
        "get_bodystructure: msg $msg returns: " . ( $bs || "UNDEF" ) );
    $bs;
}

# Updated to handle embedded literal strings
sub get_envelope {
    my ( $self, $msg ) = @_;
    unless ( eval { require Mail::IMAPClient::BodyStructure; } ) {
        $self->LastError("Unable to use get_envelope: $@");
        return undef;
    }

    my $out = $self->fetch( $msg, 'ENVELOPE' ) or return undef;

    my $bs = "";
    my $output = first { /ENVELOPE \(/i } @$out;    # vi ;-)

    unless ($output) {
        $self->LastError("Unable to use get_envelope: $@");
        return undef;
    }

    if ( $output =~ /$CRLF$/o ) {
        eval { $bs = Mail::IMAPClient::BodyStructure::Envelope->new($output) };
    }
    else {
        $self->_debug("get_envelope: reassembling original response");
        my $started = 0;
        $output = '';
        foreach my $o ( $self->_transaction ) {
            next unless $self->_is_output_or_literal($o);
            $self->_debug("o->[DATA] is $o->[DATA]");

            $started++ if $o->[DATA] =~ /ENVELOPE \(/i;    # Hi, vi! ;-)
            $started or next;

            if ( length($output) && $self->_is_literal($o) ) {
                my $data = $o->[DATA];
                $data =~ s/"/\\"/g;
                $data =~ s/\(/\\\(/g;
                $data =~ s/\)/\\\)/g;
                $output .= '"' . $data . '"';
            }
            else {
                $output .= $o->[DATA];
            }
            $self->_debug("get_envelope: reassembled output=$output<END>");
        }

        eval { $bs = Mail::IMAPClient::BodyStructure::Envelope->new($output) };
    }

    $self->_debug( "get_envelope: msg $msg returns ref: " . $bs || "UNDEF" );
    $bs;
}

# fetch( [$seq_set|ALL], @msg_data_items )
sub fetch {
    my $self = shift;
    my $what = shift || "ALL";

    my $take = $what;
    if ( $what eq 'ALL' ) {
        my $msgs = $self->messages or return undef;
        $take = $self->Range($msgs);
    }
    elsif ( ref $what || $what =~ /^[,:\d]+\w*$/ ) {
        $take = $self->Range($what);
    }

    my ( @data, $cmd );
    my ( $seq_set, @fetch_att ) = $self->_split_sequence( $take, "FETCH", @_ );

    for ( my $x = 0 ; $x <= $#$seq_set ; $x++ ) {
        my $seq = $seq_set->[$x];
        $self->_imap_uid_command( FETCH => $seq, @fetch_att, @_ )
          or return undef;
        my $res = $self->Results;

        # only keep last command and last response (* OK ...)
        $cmd = shift(@$res);
        pop(@$res) if ( $x != $#{$seq_set} );
        push( @data, @$res );
    }

    if ( $cmd and !wantarray ) {
        $cmd =~ s/^(\d+\s+.*?FETCH\s+)\S+(\s*)/$1$take$2/;
        unshift( @data, $cmd );
    }

    #wantarray ? $self->History : $self->Results;
    return wantarray ? @data : \@data;
}

# Some servers have a maximum command length.  If Maxcommandlength is
# set, split a sequence to fit within the length restriction.
sub _split_sequence {
    my ( $self, $take, @args ) = @_;

    # split take => sequence-set and (optional) fetch-att
    my ( $seq, @att ) = split( / /, $take, 2 );

    # use the entire sequence unless Maxcommandlength is set
    my @seqs;
    my $maxl = $self->Maxcommandlength;
    if ($maxl) {

        # estimate command length, the sum of the lengths of:
        #   tag, command, fetch-att + $CRLF
        push @args, $self->Transaction, $self->Uid ? "UID" : (), "\015\012";

        # do not split on anything smaller than 64 chars
        my $clen = length join( " ", @att, @args );
        my $diff = $maxl - $clen;
        my $most = $diff > 64 ? $diff : 64;

        @seqs = ( $seq =~ m/(.{1,$most})(?:,|$)/g ) if defined $seq;
        $self->_debug( "split_sequence: length($maxl-$clen) parts: ",
            $#seqs + 1 )
          if ( $#seqs != 0 );
    }
    else {
        push( @seqs, $seq ) if defined $seq;
    }
    return \@seqs, @att;
}

# fetch_hash( [$seq_set|ALL], @msg_data_items, [\%msg_by_ids] )
sub fetch_hash {
    my $self  = shift;
    my $uids  = ref $_[-1] ? pop @_ : {};
    my @words = @_;

    # take an optional leading list of messages argument or default to
    # ALL let fetch turn that list of messages into a msgref as needed
    # fetch has similar logic for dealing with message list
    my $msgs = 'ALL';
    if ( $words[0] ) {
        if ( $words[0] eq 'ALL' || ref $words[0] ) {
            $msgs = shift @words;
        }
        elsif ( $words[0] =~ s/^([,:\d]+)\s*// ) {
            $msgs = $1;
            shift @words if $words[0] eq "";
        }
    }

    # message list (if any) is now removed from @words
    my $what = join ' ', @words;

    for (@words) {
        s/([\( ])FAST([\) ])/${1}FLAGS INTERNALDATE RFC822\.SIZE$2/i;
s/([\( ])FULL([\) ])/${1}FLAGS INTERNALDATE RFC822\.SIZE ENVELOPE BODY$2/i;
    }

    my $output = $self->fetch( $msgs, "($what)" ) or return undef;

    for ( my $x = 0 ; $x <= $#$output ; $x++ ) {
        my $entry = {};
        my $l     = $output->[$x];

        if ( $self->Uid ) {
            my $uid = $l =~ /\bUID\s+(\d+)/i ? $1 : undef;
            $uid or next;

            if ( $uids->{$uid} ) { $entry = $uids->{$uid} }
            else                 { $uids->{$uid} ||= $entry }
        }
        else {
            my $mid = $l =~ /^\* (\d+) FETCH/i ? $1 : undef;
            $mid or next;

            if ( $uids->{$mid} ) { $entry = $uids->{$mid} }
            else                 { $uids->{$mid} ||= $entry }
        }

        foreach my $w (@words) {
            if ( $l =~ /\Q$w\E\s*$/i ) {
                $entry->{$w} = $output->[ $x + 1 ];
                $entry->{$w} =~ s/(?:$CR?$LF)+$//og;
                chomp $entry->{$w};
            }
            elsif (
                $l =~ /\(  # open paren followed by ...
                (?:.*\s)?  # ...optional stuff and a space
                \Q$w\E\s   # escaped fetch field<sp>
                (?:"       # then: a dbl-quote
                  (\\.|    # then bslashed anychar(s) or ...
                   [^"]+)  # ... nonquote char(s)
                "|         # then closing quote; or ...
                \(         # ...an open paren
                  ([^\)]*) # ... non-close-paren char(s)
                \)|        # then closing paren; or ...
                (\S+))     # unquoted string
                (?:\s.*)?  # possibly followed by space-stuff
                \)         # close paren
               /xi
              )
            {
                $entry->{$w} = defined $1 ? $1 : defined $2 ? $2 : $3;
            }
        }
    }
    return wantarray ? %$uids : $uids;
}

sub store {
    my ( $self, @a ) = @_;
    delete $self->{Folders};
    $self->_imap_uid_command( STORE => @a )
      or return undef;
    return wantarray ? $self->History : $self->Results;
}

sub _imap_folder_command($$@) {
    my ( $self, $command ) = ( shift, shift );
    delete $self->{Folders};
    my $folder = $self->Massage(shift);

    $self->_imap_command( join ' ', $command, $folder, @_ )
      or return undef;

    return wantarray ? $self->History : $self->Results;
}

sub subscribe($)   { shift->_imap_folder_command( SUBSCRIBE   => @_ ) }
sub unsubscribe($) { shift->_imap_folder_command( UNSUBSCRIBE => @_ ) }
sub create($)      { shift->_imap_folder_command( CREATE      => @_ ) }

sub delete($) {
    my $self = shift;
    $self->_imap_folder_command( DELETE => @_ ) or return undef;
    $self->Folder(undef);
    return wantarray ? $self->History : $self->Results;
}

# rfc2086
sub myrights($) { $_[0]->_imap_folder_command( MYRIGHTS => $_[1] ) }

sub close {
    my $self = shift;
    delete $self->{Folders};
    $self->_imap_command('CLOSE')
      or return undef;
    return wantarray ? $self->History : $self->Results;
}

sub expunge {
    my ( $self, $folder ) = @_;

    my $old = $self->Folder || '';
    if ( defined $folder && $folder eq $old ) {
        $self->_imap_command('EXPUNGE')
          or return undef;
    }
    else {
        $self->select($folder) or return undef;
        my $succ = $self->_imap_command('EXPUNGE');
        $self->select($old) or return undef;    # BUG? this should be fatal?
        $succ or return undef;
    }

    return wantarray ? $self->History : $self->Results;
}

sub uidexpunge {
    my ( $self, $msgspec ) = ( shift, shift );

    my $msg =
      UNIVERSAL::isa( $msgspec, 'Mail::IMAPClient::MessageSet' )
      ? $msgspec
      : $self->Range($msgspec);

    $msg->cat(@_) if @_;

    if ( $self->Uid ) {
        $self->_imap_command("UID EXPUNGE $msg")
          or return undef;
    }
    else {
        $self->LastError("Uid must be enabled for uidexpunge");
        return undef;
    }

    return wantarray ? $self->History : $self->Results;
}

# BUG? cleanup escaping/quoting
sub rename {
    my ( $self, $from, $to ) = @_;

    if ( $from =~ /^"(.*)"$/ ) {
        $from = $1 unless $self->exists($from);
        $from =~ s/"/\\"/g;
    }

    if ( $to =~ /^"(.*)"$/ ) {
        $to = $1 unless $self->exists($from) && $from =~ /^".*"$/;
        $to =~ s/"/\\"/g;
    }

    $self->_imap_command(qq(RENAME "$from" "$to")) ? $self : undef;
}

sub status {
    my ( $self, $folder ) = ( shift, shift );
    defined $folder or return undef;

    my $which = @_ ? join( " ", @_ ) : 'MESSAGES';

    my $box = $self->Massage($folder);
    $self->_imap_command("STATUS $box ($which)")
      or return undef;

    return wantarray ? $self->History : $self->Results;
}

sub flags {
    my ( $self, $msgspec ) = ( shift, shift );
    my $msg =
      UNIVERSAL::isa( $msgspec, 'Mail::IMAPClient::MessageSet' )
      ? $msgspec
      : $self->Range($msgspec);

    $msg->cat(@_) if @_;

    # Send command
    $self->fetch( $msg, "FLAGS" ) or return undef;

    my $u_f     = $self->Uid;
    my $flagset = {};

    # Parse results, setting entry in result hash for each line
    foreach my $line ( $self->Results ) {
        $self->_debug("flags: line = '$line'");
        if (
            $line =~ /\* \s+ (\d+) \s+ FETCH \s+    # * nnn FETCH
             \(
               (?:\s* UID \s+ (\d+) \s* )? # optional: UID nnn <space>
               FLAGS \s* \( (.*?) \) \s*   # FLAGS (\Flag1 \Flag2) <space>
               (?:\s* UID \s+ (\d+) \s* )? # optional: UID nnn
             \)
            /x
          )
        {
            my $mailid = $u_f ? ( $2 || $4 ) : $1;
            $flagset->{$mailid} = [ split " ", $3 ];
        }
    }

    # Or did he want a hash from msgid to flag array?
    return $flagset
      if ref $msgspec;

    # or did the guy want just one response? Return it if so
    my $flagsref = $flagset->{$msgspec};
    return wantarray ? @$flagsref : $flagsref;
}

# reduce a list, stripping undeclared flags. Flags with or without
# leading backslash.
sub supported_flags(@) {
    my $self = shift;
    my $sup  = $self->Supportedflags
      or return @_;

    return map { $sup->($_) } @_
      if ref $sup eq 'CODE';

    grep { $sup->{ /^\\(\S+)/ ? lc $1 : () } } @_;
}

sub parse_headers {
    my ( $self, $msgspec, @fields ) = @_;
    my $fields = join ' ', @fields;
    my $msg = ref $msgspec eq 'ARRAY' ? $self->Range($msgspec) : $msgspec;
    my $peek = !defined $self->Peek || $self->Peek ? '.PEEK' : '';

    my $string = "$msg BODY$peek"
      . ( $fields eq 'ALL' ? '[HEADER]' : "[HEADER.FIELDS ($fields)]" );

    my $raw = $self->fetch($string) or return undef;

    my %headers;    # message ids to headers
    my $h;          # fields for current msgid
    my $field;      # previous field name, for unfolding
    my %fieldmap = map { ( lc($_) => $_ ) } @fields;
    my $msgid;

    # some example responses:
    # * OK Message 1 no longer exists
    # * 1 FETCH (UID 26535 BODY[HEADER] "")
    # * 5 FETCH (UID 30699 BODY[HEADER] {1711}
    # header: value...
    foreach my $header ( map { split /$CR?$LF/o } @$raw ) {

        # little problem: Windows2003 has UID as body, not in header
        if (
            $header =~ s/^\* \s+ (\d+) \s+ FETCH \s+
                        \( (.*?) BODY\[HEADER (?:\.FIELDS)? .*? \]\s*//ix
          )
        {    # start new message header
            ( $msgid, my $msgattrs ) = ( $1, $2 );
            $h = {};
            if ( $self->Uid )    # undef when win2003
            {
                $msgid = $msgattrs =~ m/\b UID \s+ (\d+)/x ? $1 : undef;
            }

            $headers{$msgid} = $h if $msgid;
        }
        $header =~ /\S/ or next;    # skip empty lines.

        # ( for vi
        if ( $header =~ /^\)/ ) {    # end of this message
            undef $h;                # inbetween headers
            next;
        }
        elsif ( !$msgid && $header =~ /^\s*UID\s+(\d+)\s*\)/ ) {
            $headers{$1} = $h;       # finally found msgid, win2003
            undef $h;
            next;
        }

        unless ( defined $h ) {
            $self->_debug("found data between fetch headers: $header");
            next;
        }

        if ( $header and $header =~ s/^(\S+)\:\s*// ) {
            $field = $fieldmap{ lc $1 } || $1;
            push @{ $h->{$field} }, $header;
        }
        elsif ( $field and ref $h->{$field} eq 'ARRAY' ) {    # folded header
            $h->{$field}[-1] .= $header;
        }
        else {

            # show data if it is not like  '"")' or '{123}'
            $self->_debug("non-header data between fetch headers: $header")
              if ( $header !~ /^(?:\s*\"\"\)|\{\d+\})$CR?$LF$/o );
        }
    }

    # if we asked for one message, just return its hash,
    # otherwise, return hash of numbers => header hash
    ref $msgspec eq 'ARRAY' ? \%headers : $headers{$msgspec};
}

sub subject { $_[0]->get_header( $_[1], "Subject" ) }
sub date    { $_[0]->get_header( $_[1], "Date" ) }
sub rfc822_header { shift->get_header(@_) }

sub get_header {
    my ( $self, $msg, $field ) = @_;
    my $headers = $self->parse_headers( $msg, $field );
    $headers ? $headers->{$field}[0] : undef;
}

sub recent_count {
    my ( $self, $folder ) = ( shift, shift );

    $self->status( $folder, 'RECENT' )
      or return undef;

    my $r =
      first { s/\*\s+STATUS\s+.*\(RECENT\s+(\d+)\s*\)/$1/ } $self->History;
    chomp $r;
    $r;
}

sub message_count {
    my $self = shift;
    my $folder = shift || $self->Folder;

    $self->status( $folder, 'MESSAGES' )
      or return undef;

    foreach my $result ( $self->Results ) {
        return $1 if $result =~ /\(MESSAGES\s+(\d+)\s*\)/i;
    }

    undef;
}

sub recent()   { shift->search('recent') }
sub seen()     { shift->search('seen') }
sub unseen()   { shift->search('unseen') }
sub messages() { shift->search('ALL') }

sub sentbefore($$) { shift->_search_date( sentbefore => @_ ) }
sub sentsince($$)  { shift->_search_date( sentsince  => @_ ) }
sub senton($$)     { shift->_search_date( senton     => @_ ) }
sub since($$)      { shift->_search_date( since      => @_ ) }
sub before($$)     { shift->_search_date( before     => @_ ) }
sub on($$)         { shift->_search_date( on         => @_ ) }

sub _search_date($$$) {
    my ( $self, $how, $time ) = @_;
    my $imapdate;

    if ( $time =~ /\d\d-\D\D\D-\d\d\d\d/ ) {
        $imapdate = $time;
    }
    elsif ( $time =~ /^\d+$/ ) {
        my @ltime = localtime $time;
        $imapdate = sprintf( "%2.2d-%s-%4.4d",
            $ltime[3],
            $mnt[ $ltime[4] ],
            $ltime[5] + 1900 );
    }
    else {
        $self->LastError("Invalid date format supplied for '$how': $time");
        return undef;
    }

    $self->_imap_uid_command( SEARCH => $how, $imapdate )
      or return undef;

    my @hits;
    foreach ( $self->History ) {
        chomp;
        s/$CR?$LF$//o;
        s/^\*\s+SEARCH\s+//i or next;
        push @hits, grep /\d/, split;
    }
    $self->_debug("Hits are: @hits");
    return wantarray ? @hits : \@hits;
}

sub or {
    my ( $self, @what ) = @_;
    if ( @what < 2 ) {
        $self->LastError("Invalid number of arguments passed to or()");
        return undef;
    }

    my $or = "OR "
      . $self->Massage( shift @what ) . " "
      . $self->Massage( shift @what );

    $or = "OR $or " . $self->Massage($_) for @what;

    $self->_imap_uid_command( SEARCH => $or )
      or return undef;

    my @hits;
    foreach ( $self->History ) {
        chomp;
        s/$CR?$LF$//o;
        s/^\*\s+SEARCH\s+//i or next;
        push @hits, grep /\d/, split;
    }
    $self->_debug("Hits are now: @hits");

    return wantarray ? @hits : \@hits;
}

sub disconnect { shift->logout }

sub _quote_search {
    my ( $self, @args ) = @_;
    my @ret;
    foreach my $v (@args) {
        if ( ref($v) eq "SCALAR" ) {
            push( @ret, $$v );
        }
        elsif ( exists $SEARCH_KEYS{ uc($_) } ) {
            push( @ret, $v );
        }
        elsif ( @args == 1 ) {
            push( @ret, $v );    # <3.17 compat: caller responsible for quoting
        }
        else {
            push( @ret, $self->Quote($v) );
        }
    }
    return @ret;
}

sub search {
    my ( $self, @args ) = @_;

    @args = $self->_quote_search(@args);

    $self->_imap_uid_command( SEARCH => @args )
      or return undef;

    my @hits;
    foreach ( $self->History ) {
        chomp;
        s/$CR?$LF$//o;
        s/^\*\s+SEARCH\s+(?=.*?\d)// or next;
        push @hits, grep /^\d+$/, split;
    }

    @hits
      or $self->_debug("Search successful but found no matching messages");

    # return empty list
    return
        wantarray     ? @hits
      : !@hits        ? \@hits
      : $self->Ranges ? $self->Range( \@hits )
      :                 \@hits;
}

# returns a Thread data structure
my $thread_parser;

sub thread {
    my $self = shift;

    return undef unless defined $self->has_capability("THREAD=REFERENCES");
    my $algorythm = shift
      || (
        $self->has_capability("THREAD=REFERENCES")
        ? 'REFERENCES'
        : 'ORDEREDSUBJECT'
      );

    my $charset = shift || 'UTF-8';
    my @a = @_ ? @_ : 'ALL';

    $a[-1] = $self->Massage( $a[-1], 1 )
      if @a > 1 && !exists $SEARCH_KEYS{ uc $a[-1] };

    $self->_imap_uid_command( THREAD => $algorythm, $charset, @a )
      or return undef;

    unless ($thread_parser) {
        return if $thread_parser == 0;

        eval { require Mail::IMAPClient::Thread; };
        if ($@) {
            $self->LastError($@);
            $thread_parser = 0;
            return undef;
        }
        $thread_parser = Mail::IMAPClient::Thread->new;
    }

    my $thread;
    foreach ( $self->History ) {
        /^\*\s+THREAD\s+/ or next;
        s/$CR?$LF|$LF+/ /og;
        $thread = $thread_parser->start($_);
    }

    unless ($thread) {
        $self->LastError(
"Thread search completed successfully but found no matching messages"
        );
        return undef;
    }

    $thread;
}

sub delete_message {
    my $self = shift;
    my @msgs = map { ref $_ eq 'ARRAY' ? @$_ : split /\,/ } @_;

    $self->store( join( ',', @msgs ), '+FLAGS.SILENT', '(\Deleted)' )
      ? scalar @msgs
      : undef;
}

sub restore_message {
    my $self = shift;
    my $msgs = join ',', map { ref $_ eq 'ARRAY' ? @$_ : split /\,/ } @_;

    $self->store( $msgs, '-FLAGS', '(\Deleted)' ) or return undef;
    scalar grep /^\*\s\d+\sFETCH\s\(.*FLAGS.*(?!\\Deleted)/, $self->Results;
}

#??? compare to uidnext.  Why is Massage missing?
sub uidvalidity {
    my ( $self, $folder ) = @_;
    $self->status( $folder, "UIDVALIDITY" ) or return undef;
    my $vline = first { /UIDVALIDITY/i } $self->History;
    defined $vline && $vline =~ /\(UIDVALIDITY\s+([^\)]+)/ ? $1 : undef;
}

sub uidnext {
    my $self   = shift;
    my $folder = $self->Massage(shift);
    $self->status( $folder, "UIDNEXT" ) or return undef;
    my $line = first { /UIDNEXT/i } $self->History;
    defined $line && $line =~ /\(UIDNEXT\s+([^\)]+)/ ? $1 : undef;
}

sub capability {
    my $self = shift;

    if ( $self->{CAPABILITY} ) {
        my @caps = keys %{ $self->{CAPABILITY} };
        return wantarray ? @caps : \@caps;
    }

    $self->_imap_command('CAPABILITY')
      or return undef;

    my @caps = map { split } grep s/^\*\s+CAPABILITY\s+//, $self->History;
    foreach (@caps) {
        $self->{CAPABILITY}{ uc $_ }++;
        $self->{ uc $1 } = uc $2 if /(.*?)\=(.*)/;
    }

    return wantarray ? @caps : \@caps;
}

# use "" not undef when lookup fails to differentiate imap command
# failure vs lack of capability
sub has_capability {
    my ( $self, $which ) = @_;
    $self->capability or return undef;
    $which ? $self->{CAPABILITY}{ uc $which } : "";
}

sub imap4rev1 {
    my $self = shift;
    return $self->{_IMAP4REV1} if exists $self->{_IMAP4REV1};
    $self->{_IMAP4REV1} = $self->has_capability('IMAP4REV1');
}

#??? what a horror!
sub namespace {

    # Returns a nested list as follows:
    # [
    #  [
    #   [ $user_prefix,  $user_delim  ] (,[$user_prefix2  ,$user_delim  ],...),
    #  ],
    #  [
    #   [ $shared_prefix,$shared_delim] (,[$shared_prefix2,$shared_delim],... ),
    #  ],
    #  [
    #   [$public_prefix, $public_delim] (,[$public_prefix2,$public_delim],...),
    #  ],
    # ];

    my $self = shift;
    unless ( $self->has_capability("NAMESPACE") ) {
        $self->LastError( "NO NAMESPACE not supported by " . $self->Server )
          unless $self->LastError;
        return undef;
    }

    my $got = $self->_imap_command("NAMESPACE") or return undef;
    my @namespaces = map { /^\* NAMESPACE (.*)/ ? $1 : () } $got->Results;

    my $namespace = shift @namespaces;
    $namespace =~ s/$CR?$LF$//o;

    my ( $personal, $shared, $public ) = $namespace =~ m#
        (NIL|\((?:\([^\)]+\)\s*)+\))\s
        (NIL|\((?:\([^\)]+\)\s*)+\))\s
        (NIL|\((?:\([^\)]+\)\s*)+\))
    #xi;

    my @ns;
    $self->_debug("NAMESPACE: pers=$personal, shared=$shared, pub=$public");
    foreach ( $personal, $shared, $public ) {
        uc $_ ne 'NIL' or next;
        s/^\((.*)\)$/$1/;

        my @pieces = m#\(([^\)]*)\)#g;
        $self->_debug("NAMESPACE pieces: @pieces");

        push @ns, [ map { [m#"([^"]*)"\s*#g] } @pieces ];
    }

    return wantarray ? @ns : \@ns;
}

sub internaldate {
    my ( $self, $msg ) = @_;
    $self->_imap_uid_command( FETCH => $msg, 'INTERNALDATE' )
      or return undef;
    my $internalDate = join '', $self->History;
    $internalDate =~ s/^.*INTERNALDATE "//si;
    $internalDate =~ s/\".*$//s;
    $internalDate;
}

sub is_parent {
    my ( $self, $folder ) = ( shift, shift );
    my $list = $self->list( undef, $folder ) or return undef;

    my $attrs;
    foreach my $resp (@$list) {
        my $rec = $self->_list_or_lsub_response_parse($resp);
        next unless defined $rec->{attrs};
        return 0 if $rec->{attrs} =~ /\bNoInferior\b/i;
        $attrs = $rec->{attrs};
    }

    if ($attrs) {
        return 1 if $attrs =~ /HasChildren/i;
        return 0 if $attrs =~ /HasNoChildren/i;
    }
    else {
        $self->_debug( join( "\n\t", "no attrs for '$folder' in:", @$list ) );
    }

    # BUG? This may be overkill for normal use cases...
    # flag not supported or not returned for some reason, try via folders()
    my $sep = $self->separator($folder) || $self->separator(undef);
    return undef unless defined $sep;

    my $lead = $folder . $sep;
    my $len  = length $lead;
    scalar grep { $lead eq substr( $_, 0, $len ) } $self->folders;
}

sub selectable {
    my ( $self, $f ) = @_;
    my $info = $self->list( "", $f );
    defined $info ? not( grep /NoSelect/i, @$info ) : undef;
}

sub append {
    my $self   = shift;
    my $folder = shift;
    my $text   = @_ > 1 ? join( $CRLF, @_ ) : shift;

    $self->append_string( $folder, $text );
}

sub append_string($$$;$$) {
    my $self   = shift;
    my $folder = $self->Massage(shift);
    my ( $text, $flags, $date ) = @_;
    defined $text or $text = '';

    if ( defined $flags ) {
        $flags =~ s/^\s+//g;
        $flags =~ s/\s+$//g;
        $flags = "($flags)" if $flags !~ /^\(.*\)$/;
    }

    if ( defined $date ) {
        $date =~ s/^\s+//g;
        $date =~ s/\s+$//g;
        $date = qq("$date") if $date !~ /^"/;
    }

    $text =~ s/\r?\n/$CRLF/og;

    my $command =
        "APPEND $folder "
      . ( $flags ? "$flags " : "" )
      . ( $date  ? "$date "  : "" ) . "{"
      . length($text)
      . "}$CRLF";

    $command .= $text . $CRLF;
    $self->_imap_command( { addcrlf => 0 }, $command ) or return undef;

    my $data = join '', $self->Results;

    # look for something like return size or self if no size found:
    # <tag> OK [APPENDUID <uid> <size>] APPEND completed
    my $ret = $data =~ m#\s+(\d+)\]# ? $1 : $self;

    return $ret;
}

sub append_file {
    my ( $self, $folder, $file, $control, $flags, $use_filetime ) = @_;
    my $mfolder = $self->Massage($folder);

    $flags ||= '';
    my $fflags = $flags =~ m/^\(.*\)$/ ? $flags : "($flags)";

    my @err;
    push( @err, "folder not specified" )
      unless ( defined($folder) and $folder ne "" );

    my $fh;
    if ( !defined($file) ) {
        push( @err, "file not specified" );
    }
    elsif ( ref($file) ) {
        $fh = $file;    # let the caller pass in their own file handle directly
    }
    elsif ( !-f $file ) {
        push( @err, "file '$file' not found" );
    }
    else {
        $fh = IO::File->new( $file, 'r' )
          or push( @err, "Unable to open file '$file': $!" );
    }

    if (@err) {
        $self->LastError( join( ", ", @err ) );
        return undef;
    }

    my $date;
    if ( $fh and $use_filetime ) {
        my $f = $self->Rfc2060_datetime( ( stat($fh) )[9] );
        $date = qq("$f");
    }

    # BUG? seems wasteful to do this always, provide a "fast path" option?
    my $length = 0;
    {
        local $/ = "\n";    # just in case global is not default
        while ( my $line = <$fh> ) {    # do no read the whole file at once!
            $line =~ s/\r?\n$/$CRLF/;
            $length += length($line);
        }
        seek( $fh, 0, 0 );
    }

    my $string = "APPEND $mfolder";
    $string .= " $fflags" if ( $fflags ne "" );
    $string .= " $date"   if ( defined($date) );
    $string .= " {$length}";

    my $rc = $self->_imap_command( $string, '+' );
    unless ($rc) {
        $self->LastError( "Error sending '$string': " . $self->LastError );
        return undef;
    }

    my $count = $self->Count;

    # Now send the message itself
    my $buffer;
    while ( $fh->sysread( $buffer, APPEND_BUFFER_SIZE ) ) {
        $buffer =~ s/\r?\n/$CRLF/og;

        $self->_record(
            $count,
            [
                $self->_next_index($count), "INPUT",
                '{' . length($buffer) . " bytes from $file}"
            ]
        );

        my $bytes_written = $self->_send_bytes( \$buffer );
        unless ($bytes_written) {
            $self->LastError( "Error appending message: " . $self->LastError );
            return undef;
        }
    }

    # finish off append
    unless ( $self->_send_bytes( \$CRLF ) ) {
        $self->LastError( "Error appending CRLF: " . $self->LastError );
        return undef;
    }

    # Now for the crucial test: Did the append work or not?
    # look for "<tag> (OK|BAD|NO)"
    my $code = $self->_get_response($count) or return undef;

    if ( $code eq 'OK' ) {
        my $data = join '', $self->Results;

        # look for something like return size or self if no size found:
        # <tag> OK [APPENDUID <uid> <size>] APPEND completed
        my $ret = $data =~ m#\s+(\d+)\]# ? $1 : $self;

        return $ret;
    }
    else {
        return undef;
    }
}

# BUG? we should retry if "socket closed while..." but do not currently
sub authenticate {
    my ( $self, $scheme, $response ) = @_;
    $scheme   ||= $self->Authmechanism;
    $response ||= $self->Authcallback;
    my $clear = $self->Clear;
    $self->Clear($clear)
      if $self->Count >= $clear && $clear > 0;

    if ( !$scheme ) {
        $self->LastError("Authmechanism not set");
        return undef;
    }
    elsif ( $scheme eq 'LOGIN' ) {
        $self->LastError("Authmechanism LOGIN is invalid, use login()");
        return undef;
    }

    my $string = "AUTHENTICATE $scheme";

    # use _imap_command for retry mechanism...
    $self->_imap_command( $string, '+' ) or return undef;

    my $count = $self->Count;
    my $code;

    # look for "+ <anyword>" or just "+"
    foreach my $line ( $self->Results ) {
        if ( $line =~ /^\+\s*(.*?)\s*$/ ) {
            $code = $1;
            last;
        }
    }

    if ( $scheme eq 'CRAM-MD5' ) {
        $response ||= sub {
            my ( $code, $client ) = @_;
            require Digest::HMAC_MD5;
            my $hmac =
              Digest::HMAC_MD5::hmac_md5_hex( decode_base64($code),
                $client->Password );
            encode_base64( $client->User . " " . $hmac, '' );
        };
    }
    elsif ( $scheme eq 'DIGEST-MD5' ) {
        $response ||= sub {
            my ( $code, $client ) = @_;
            require Authen::SASL;
            require Digest::MD5;

            my $authname =
              defined $client->Authuser ? $client->Authuser : $client->User;

            my $sasl = Authen::SASL->new(
                mechanism => 'DIGEST-MD5',
                callback  => {
                    user     => $client->User,
                    pass     => $client->Password,
                    authname => $authname
                }
            );

            # client_new is an empty function for DIGEST-MD5
            my $conn = $sasl->client_new( 'imap', 'localhost', '' );
            my $answer = $conn->client_step( decode_base64 $code);

            encode_base64( $answer, '' )
              if defined $answer;
        };
    }
    elsif ( $scheme eq 'PLAIN' ) {    # PLAIN SASL
        $response ||= sub {
            my ( $code, $client ) = @_;
            encode_base64(
                $client->User
                  . chr(0)
                  . $client->Proxy
                  . chr(0)
                  . $client->Password,
                ''
            );
        };
    }
    elsif ( $scheme eq 'NTLM' ) {
        $response ||= sub {
            my ( $code, $client ) = @_;

            require Authen::NTLM;
            Authen::NTLM::ntlm_user( $self->User );
            Authen::NTLM::ntlm_password( $self->Password );
            Authen::NTLM::ntlm_domain( $self->Domain ) if $self->Domain;
            Authen::NTLM::ntlm();
        };
    }

    unless ( $self->_send_line( $response->( $code, $self ) ) ) {
        $self->LastError( "Error sending $scheme data: " . $self->LastError );
        return undef;
    }

    # this code may be a little too custom to try and use _get_response()
    # look for "+ <anyword>" (not just "+") otherwise "<tag> (OK|BAD|NO)"
    undef $code;
    until ($code) {
        my $output = $self->_read_line or return undef;
        foreach my $o (@$output) {
            $self->_record( $count, $o );
            $code = $o->[DATA] =~ /^\+\s+(.*?)\s*$/ ? $1 : undef;

            if ($code) {
                unless ( $self->_send_line( $response->( $code, $self ) ) ) {
                    $self->LastError(
                        "Error sending $scheme data: " . $self->LastError );
                    return undef;
                }
                undef $code;    # clear code as we are not finished yet
            }

            if ( $o->[DATA] =~ /^$count\s+(OK|NO|BAD)\b/i ) {
                $code = uc($1);
                $self->LastError( $o->[DATA] ) unless ( $code eq 'OK' );
            }
            elsif ( $o->[DATA] =~ /^\*\s+BYE/ ) {
                $self->State(Unconnected);
                $self->LastError( $o->[DATA] );
                return undef;
            }
        }
    }

    return undef unless $code eq 'OK';

    Authen::NTLM::ntlm_reset()
      if $scheme eq 'NTLM';

    $self->State(Authenticated);
    return $self;
}

# UIDPLUS response from a copy: [COPYUID (uidvalidity) (origuid) (newuid)]
sub copy {
    my ( $self, $target, @msgs ) = @_;

    $target = $self->Massage($target);
    @msgs =
        $self->Ranges
      ? $self->Range(@msgs)
      : sort { $a <=> $b } map { ref $_ ? @$_ : split( ',', $_ ) } @msgs;

    my $msgs =
        $self->Ranges
      ? $self->Range(@msgs)
      : join ',', map { ref $_ ? @$_ : $_ } @msgs;

    $self->_imap_uid_command( COPY => $msgs, $target )
      or return undef;

    my @results = $self->History;

    my @uids;
    foreach (@results) {
        chomp;
        s/$CR?$LF$//o;
        s/^.*\[COPYUID\s+\d+\s+[\d:,]+\s+([\d:,]+)\].*/$1/ or next;
        push @uids, /(\d+):(\d+)/ ? ( $1 ... $2 ) : ( split /\,/ );

    }
    return @uids ? join( ",", @uids ) : $self;
}

sub move {
    my ( $self, $target, @msgs ) = @_;

    $self->exists($target)
      or $self->create($target) && $self->subscribe($target);

    my $uids =
      $self->copy( $target, map { ref $_ eq 'ARRAY' ? @$_ : $_ } @msgs )
      or return undef;

    unless ( $self->delete_message(@msgs) ) {
        local ($!);    # old versions of Carp could reset $!
        carp $self->LastError;
    }

    return $uids;
}

sub set_flag {
    my ( $self, $flag, @msgs ) = @_;
    @msgs = @{ $msgs[0] } if ref $msgs[0] eq 'ARRAY';
    $flag = "\\$flag"
      if $flag =~ /^(?:Answered|Flagged|Deleted|Seen|Draft)$/i;

    my $which = $self->Ranges ? $self->Range(@msgs) : join( ',', @msgs );
    return $self->store( $which, '+FLAGS.SILENT', "($flag)" );
}

sub see {
    my ( $self, @msgs ) = @_;
    @msgs = @{ $msgs[0] } if ref $msgs[0] eq 'ARRAY';
    return $self->set_flag( '\\Seen', @msgs );
}

sub mark {
    my ( $self, @msgs ) = @_;
    @msgs = @{ $msgs[0] } if ref $msgs[0] eq 'ARRAY';
    return $self->set_flag( '\\Flagged', @msgs );
}

sub unmark {
    my ( $self, @msgs ) = @_;
    @msgs = @{ $msgs[0] } if ref $msgs[0] eq 'ARRAY';
    return $self->unset_flag( '\\Flagged', @msgs );
}

sub unset_flag {
    my ( $self, $flag, @msgs ) = @_;
    @msgs = @{ $msgs[0] } if ref $msgs[0] eq 'ARRAY';

    $flag = "\\$flag"
      if $flag =~ /^(?:Answered|Flagged|Deleted|Seen|Draft)$/i;

    return $self->store( join( ",", @msgs ), "-FLAGS.SILENT ($flag)" );
}

sub deny_seeing {
    my ( $self, @msgs ) = @_;
    @msgs = @{ $msgs[0] } if ref $msgs[0] eq 'ARRAY';
    return $self->unset_flag( '\\Seen', @msgs );
}

sub size {
    my ( $self, $msg ) = @_;
    my $data = $self->fetch( $msg, "(RFC822.SIZE)" ) or return undef;

    # beware of response like: * NO Cannot open message $msg
    my $cmd = shift @$data;
    my $err;
    foreach my $line (@$data) {
        return $1 if ( $line =~ /RFC822\.SIZE\s+(\d+)/ );
        $err = $line if ( $line =~ /\* NO\b/ );
    }

    if ($err) {
        my $info = "$err was returned for $cmd";
        $info =~ s/$CR?$LF//og;
        $self->LastError($info);
    }
    elsif ( !$self->LastError ) {
        my $info = "no RFC822.SIZE found in: " . join( " ", @$data );
        $self->LastError($info);
    }
    return undef;
}

sub getquotaroot {
    my ( $self, $what ) = @_;
    my $who = $what ? $self->Massage($what) : "INBOX";
    return $self->_imap_command("GETQUOTAROOT $who") ? $self->Results : undef;
}

sub getquota {
    my ( $self, $what ) = @_;
    my $who = $what ? $self->Massage($what) : "user/$self->{User}";
    return $self->_imap_command("GETQUOTA $who") ? $self->Results : undef;
}

# usage: $self->setquota($folder, storage => 512)
sub setquota(@) {
    my ( $self, $what ) = ( shift, shift );
    my $who = $what ? $self->Massage($what) : "user/$self->{User}";
    my @limits;
    while (@_) {
        my $key = uc shift @_;
        push @limits, $key => shift @_;
    }
    local $" = ' ';
    $self->_imap_command("SETQUOTA $who (@limits)") ? $self->Results : undef;
}

sub quota {
    my $self = shift;
    my $what = shift || "INBOX";
    $self->_imap_command("GETQUOTA $what") or $self->getquotaroot($what);
    ( map { /.*STORAGE\s+\d+\s+(\d+).*\n$/ ? $1 : () } $self->Results )[0];
}

sub quota_usage {
    my $self = shift;
    my $what = shift || "INBOX";
    $self->_imap_command("GETQUOTA $what") || $self->getquotaroot($what);
    ( map { /.*STORAGE\s+(\d+)\s+\d+.*\n$/ ? $1 : () } $self->Results )[0];
}

sub Quote($) { $_[0]->Massage( $_[1], NonFolderArg ) }

# rfc3501:
#   atom-specials   = "(" / ")" / "{" / SP / CTL / list-wildcards /
#                  quoted-specials / resp-specials
#   list-wildcards  = "%" / "*"
#   quoted-specials = DQUOTE / "\"
#   resp-specials   = "]"
# rfc2060:
#   CTL ::= <any ASCII control character and DEL, 0x00 - 0x1f, 0x7f>
# Additionally, we encode strings with } and [, be less than minimal
sub Massage($;$) {
    my ( $self, $name, $notFolder ) = @_;
    $name =~ s/^\"(.*)\"$/$1/ unless $notFolder;

    if ( $name =~ /["\\]/ ) {
        return "{" . length($name) . "}" . $CRLF . $name;
    }
    elsif ( $name =~ /[(){}\s[:cntrl:]%*\[\]]/ ) {
        return qq("$name");
    }
    else {
        return $name;
    }
}

sub unseen_count {
    my ( $self, $folder ) = ( shift, shift );
    $folder ||= $self->Folder;
    $self->status( $folder, 'UNSEEN' ) or return undef;

    my $r =
      first { s/\*\s+STATUS\s+.*\(UNSEEN\s+(\d+)\s*\)/$1/ } $self->History;

    $r =~ s/\D//g;
    return $r;
}

sub Status          { shift->State }
sub IsUnconnected   { shift->State == Unconnected }
sub IsConnected     { shift->State >= Connected }
sub IsAuthenticated { shift->State >= Authenticated }
sub IsSelected      { shift->State == Selected }

# The following private methods all work on an output line array.
# _data returns the data portion of an output array:
sub _data { ref $_[1] && defined $_[1]->[TYPE] ? $_[1]->[DATA] : undef }

# _index returns the index portion of an output array:
sub _index { ref $_[1] && defined $_[1]->[TYPE] ? $_[1]->[INDEX] : undef }

# _type returns the type portion of an output array:
sub _type { ref $_[1] && $_[1]->[TYPE] }

# _is_literal returns true if this is a literal:
sub _is_literal { ref $_[1] && $_[1]->[TYPE] && $_[1]->[TYPE] eq 'LITERAL' }

# _is_output_or_literal returns true if this is an
#      output line (or the literal part of one):

sub _is_output_or_literal {
    ref $_[1]
      && defined $_[1]->[TYPE]
      && ( $_[1]->[TYPE] eq "OUTPUT" || $_[1]->[TYPE] eq "LITERAL" );
}

# _is_output returns true if this is an output line:
sub _is_output { ref $_[1] && $_[1]->[TYPE] && $_[1]->[TYPE] eq "OUTPUT" }

# _is_input returns true if this is an input line:
sub _is_input { ref $_[1] && $_[1]->[TYPE] && $_[1]->[TYPE] eq "INPUT" }

# _next_index returns next_index for a transaction; may legitimately
# return 0 when successful.
sub _next_index { my $r = $_[0]->_transaction( $_[1] ); $r }

sub Range {
    my ( $self, $targ ) = ( shift, shift );

    UNIVERSAL::isa( $targ, 'Mail::IMAPClient::MessageSet' )
      ? $targ->cat(@_)
      : Mail::IMAPClient::MessageSet->new( $targ, @_ );
}

1;
