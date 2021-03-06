#
# Copyright (c) 2006, 2007 Michael Schroeder, Novell Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
#
# Event based HTTP Server. Only supports GET requests.
#

package BSServerEvents;

use POSIX;
use Socket;
use Fcntl qw(:DEFAULT);
use Symbol;
use BSEvents;
use BSHTTP;
use Data::Dumper;

use strict;

our $gev;	# our event

# FIXME: should not set global
$BSServer::request if 0;	# get rid of used only once warning

sub replstream_timeout {
  my ($ev) = @_;
  print "replstream timeout for $ev->{'peer'}\n";
  stream_close($ev->{'readev'}, $ev);
}

sub replrequest_timeout {
  my ($ev) = @_;
  print "replrequest timeout for $ev->{'peer'}\n";
  $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
  close($ev->{'fd'});
  close($ev->{'nfd'}) if $ev->{'nfd'};
  delete $ev->{'fd'};
  delete $ev->{'nfd'};
}

sub replrequest_write {
  my ($ev) = @_;
  my $l = length($ev->{'replbuf'});
  return unless $l;
  $l = 4096 if $l > 4096;
  my $r = syswrite($ev->{'fd'}, $ev->{'replbuf'}, $l);
  if (!defined($r)) {
    if ($! == POSIX::EINTR || $! == POSIX::EWOULDBLOCK) {
      BSEvents::add($ev);
      return;
    }
    print "write error for $ev->{'peer'}: $!\n";
    $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
    close($ev->{'fd'});
    close($ev->{'nfd'}) if $ev->{'nfd'};
    return;
  }
  if ($r == length($ev->{'replbuf'})) {
    #print "done for $ev->{'peer'}\n";
    $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
    close($ev->{'fd'});
    close($ev->{'nfd'}) if $ev->{'nfd'};
    return;
  }
  $ev->{'replbuf'} = substr($ev->{'replbuf'}, $r) if $r;
  BSEvents::add($ev);
  return;
}

sub reply {
  my ($str, @hdrs) = @_;
  my $ev = $gev;
  # print "reply to event #$ev->{'id'}\n";
  if (!exists($ev->{'fd'})) {
    $ev->{'handler'}->($ev) if $ev->{'handler'};
    $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
    print "$str\n" if defined($str) && $str ne '';
    return;
  }
  if ($ev->{'streaming'}) {
    # already in progress, can not do much here...
    $ev->{'replbuf'} .= "\n\n$str" if defined $str;
    $ev->{'type'} = 'write';
    $ev->{'handler'} = \&replrequest_write;
    $ev->{'timeouthandler'} = \&replrequest_timeout;
    BSEvents::add($ev, $ev->{'conf'}->{'replrequest_timeout'});
    return;
  }
  if (@hdrs && $hdrs[0] =~ /^status: (\d+.*)/i) {
    my $msg = $1;
    $msg =~ s/:/ /g;
    $hdrs[0] = "HTTP/1.1 $msg";
  } else {
    unshift @hdrs, "HTTP/1.1 200 OK";
  }
  push @hdrs, "Cache-Control: no-cache";
  push @hdrs, "Connection: close";
  push @hdrs, "Content-Length: ".length($str) if defined $str;
  my $data = join("\r\n", @hdrs)."\r\n\r\n";
  $data .= $str if defined $str;
  my $dummy = '';
  sysread($ev->{'fd'}, $dummy, 1024, 0);	# clear extra input
  $ev->{'replbuf'} = $data;
  $ev->{'type'} = 'write';
  $ev->{'handler'} = \&replrequest_write;
  $ev->{'timeouthandler'} = \&replrequest_timeout;
  BSEvents::add($ev, $ev->{'conf'}->{'replrequest_timeout'});
}

sub reply_error  {
  my ($conf, $errstr) = @_;
  my ($err, $code, $tag, @hdrs) = BSServer::parse_error_string($conf, $errstr);
  if ($conf && $conf->{'errorreply'}) {
    $conf->{'errorreply'}->($err, $code, $tag, @hdrs);
  } else {
    reply("$err\n", "Status: $code $tag", 'Content-Type: text/plain', @hdrs);
  }
}

sub reply_stream {
  my ($rev, @hdrs) = @_;
  push @hdrs, 'Transfer-Encoding: chunked';
  unshift @hdrs, 'Content-Type: application/octet-stream' unless grep {/^content-type:/i} @hdrs;
  reply(undef, @hdrs);
  my $ev = $gev;
  BSEvents::rem($ev);
  #print "reply_stream $rev -> $ev\n";
  $ev->{'readev'} = $rev;
  $ev->{'handler'} = \&stream_write_handler;
  $ev->{'timeouthandler'} = \&replstream_timeout;
  $ev->{'streaming'} = 1;
  $rev->{'writeev'} = $ev;
  $rev->{'handler'} ||= \&stream_read_handler;
  BSEvents::add($ev, 0);
  BSEvents::add($rev);	# do this last (because of "always" type)
}

sub reply_file {
  my ($filename, @hdrs) = @_;
  my $fd = $filename;
  if (!ref($fd)) {
    $fd = gensym;
    open($fd, '<', $filename) || die("$filename: $!\n");
  }
  my $rev = BSEvents::new('always');
  $rev->{'fd'} = $fd;
  $rev->{'makechunks'} = 1;
  reply_stream($rev, @hdrs);
}

sub cpio_nextfile {
  my ($ev) = @_;

  my $data = '';
  while(1) {
    #print "cpio_nextfile\n";
    $data .= $ev->{'filespad'} if defined $ev->{'filespad'};
    delete $ev->{'filespad'};
    my $files = $ev->{'files'};
    my $filesno = defined($ev->{'filesno'}) ? $ev->{'filesno'} + 1 : 0;
    my $file;
    if ($filesno >= @$files) {
      if ($ev->{'cpioerrors'} ne '') {
	$file = {'data' => $ev->{'cpioerrors'}, 'name' => '.errors'};
	$ev->{'cpioerrors'} = '';
      } else {
	$data .= BSHTTP::makecpiohead();
	return $data;
      }
    } else {
      $ev->{'filesno'} = $filesno;
      $file = $files->[$filesno];
    }
    if ($file->{'error'}) {
      $ev->{'cpioerrors'} .= "$file->{'name'}: $file->{'error'}\n";
      next;
    }
    my @s;
    if (exists $file->{'filename'}) {
      my $fd = $file->{'filename'};
      if (!ref($fd)) {
	$fd = gensym;
	if (!open($fd, '<', $file->{'filename'})) {
	  $ev->{'cpioerrors'} .= "$file->{'name'}: $file->{'filename'}: $!\n";
	  next;
	}
      }
      @s = stat($fd);
      if (!@s) {
	$ev->{'cpioerrors'} .= "$file->{'name'}: stat: $!\n";
	close($fd) if !ref($file->{'filename'});
	next;
      }
      if (ref($file->{'filename'})) {
	my $off = sysseek($fd, 0, Fcntl::SEEK_CUR) || 0;
	$s[7] -= $off if $off > 0;
      }
      $ev->{'fd'} = $fd;
    } else {
      $s[7] = length($file->{'data'});
      $s[9] = time();
    }
    my ($header, $pad) = BSHTTP::makecpiohead($file, \@s);
    $data .= $header;
    $ev->{'filespad'} = $pad;
    if (!exists $file->{'filename'}) {
      $data .= $file->{'data'};
      next;
    }
    return $data;
  }
}

sub reply_cpio {
  my ($files, @hdrs) = @_;
  my $rev = BSEvents::new('always');
  $rev->{'files'} = $files;
  $rev->{'cpioerrors'} = '';
  $rev->{'makechunks'} = 1;
  $rev->{'eofhandler'} = \&cpio_nextfile;
  unshift @hdrs, 'Content-Type: application/x-cpio';
  reply_stream($rev, @hdrs);
}

sub getrequest_timeout {
  my ($ev) = @_;
  print "getrequest timeout for $ev->{'peer'}\n";
  $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
  close($ev->{'fd'});
  close($ev->{'nfd'}) if $ev->{'nfd'};
}

sub getrequest {
  my ($ev) = @_;
  my $buf;
  local $gev = $ev;

  eval {
    $ev->{'reqbuf'} = '' unless exists $ev->{'reqbuf'};
    my $r;
    if ($ev->{'reqbuf'} eq '' && exists $ev->{'conf'}->{'getrequest_recvfd'}) {
      my $newfd = gensym;
      $r = $ev->{'conf'}->{'getrequest_recvfd'}->($ev->{'fd'}, $newfd, 1024);
      if (defined($r)) {
	if (-c $newfd) {
	  close $newfd;	# /dev/null case, no handoff requested
	} else {
          $ev->{'nfd'} = $newfd;
	}
        $ev->{'reqbuf'} = $r;
        $r = length($r);
      }
    } else {
      $r = sysread($ev->{'fd'}, $ev->{'reqbuf'}, 1024, length($ev->{'reqbuf'}));
    }
    if (!defined($r)) {
      if ($! == POSIX::EINTR || $! == POSIX::EWOULDBLOCK) {
        BSEvents::add($ev);
        return;
      }
      print "read error for $ev->{'peer'}: $!\n";
      $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
      close($ev->{'fd'});
      close($ev->{'nfd'}) if $ev->{'nfd'};
      return;
    }
    if (!$r) {
      print "EOF for $ev->{'peer'}\n";
      $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
      close($ev->{'fd'});
      close($ev->{'nfd'}) if $ev->{'nfd'};
      return;
    }
    if ($ev->{'reqbuf'} !~ /^(.*?)\r?\n/s) {
      BSEvents::add($ev);
      return;
    }
    my ($act, $path, $vers, undef) = split(' ', $1, 4);
    die("400 No method name\n") if !$act;
    my $headers = {};
    if ($vers) {
      die("501 Bad method: $act\n") if $act ne 'GET';
      if ($ev->{'reqbuf'} !~ /^(.*?)\r?\n\r?\n(.*)$/s) {
	BSEvents::add($ev);
	return;
      }
      BSHTTP::gethead($headers, "Request: $1");
    } else {
      die("501 Bad method, must be GET\n") if $act ne 'GET';
    }
    my $query_string = '';
    if ($path =~ /^(.*?)\?(.*)$/) {
      $path = $1;
      $query_string = $2;
    }
    $path =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/ge;
    die("501 invalid path\n") unless $path =~ /^\//;
    my $conf = $ev->{'conf'};
    my $req = {'action' => $act, 'path' => $path, 'query' => $query_string, 'headers' => $headers, 'peer' => $ev->{'peer'}, 'conf' => $conf};
    $req->{'peerport'} = $ev->{'peerport'} if $ev->{'peerport'};
    $ev->{'request'} = $req;
    # FIXME: should not use global
    $BSServer::request = $req;
    my @r = $conf->{'dispatch'}->($conf, $req);
    if ($conf->{'stdreply'}) {
      $conf->{'stdreply'}->(@r);
    } elsif (@r && (@r != 1 || defined($r[0]))) {
      reply(@r);
    }
  };
  reply_error($ev->{'conf'}, $@) if $@;
}

sub newconnect {
  my ($ev) = @_;
  #print "newconnect!\n";
  BSEvents::add($ev);
  my $newfd = gensym;
  my $peeraddr = accept($newfd, *{$ev->{'fd'}});
  return unless $peeraddr;
  fcntl($newfd, F_SETFL, O_NONBLOCK);
  my $peer = 'unknown';
  my $peerport;
  eval {
    my $peera;
    ($peerport, $peera) = sockaddr_in($peeraddr);
    $peer = inet_ntoa($peera);
  };
  my $cev = BSEvents::new('read', \&getrequest);
  $cev->{'fd'} = $newfd;
  $cev->{'peer'} = $peer;
  $cev->{'peerport'} = $peerport if $peerport;
  $cev->{'timeouthandler'} = \&getrequest_timeout;
  $cev->{'conf'} = $ev->{'conf'};
  if ($cev->{'conf'}->{'setkeepalive'}) {
    setsockopt($cev->{'fd'}, SOL_SOCKET, SO_KEEPALIVE, pack("l",1));
  }
  BSEvents::add($cev, $ev->{'conf'}->{'getrequest_timeout'});
}

sub cloneconnect {
  my (@reply) = @_;
  my $ev = $gev;
  return $ev unless exists $ev->{'nfd'};
  fcntl($ev->{'nfd'}, F_SETFL, O_NONBLOCK);
  my $nev = BSEvents::new('read', $ev->{'handler'});
  $nev->{'fd'} = $ev->{'nfd'};
  delete $ev->{'nfd'};
  $nev->{'conf'} = $ev->{'conf'};
  $nev->{'request'} = { %{$ev->{'request'}} } if $ev->{'request'};
  my $peer = 'unknown';
  my $peerport;
  eval {
    my $peeraddr = getpeername($nev->{'fd'});
    if ($peeraddr) {
      my $peera;
      ($peerport, $peera) = sockaddr_in($peeraddr);
      $peer = inet_ntoa($peera);
    }
  };
  $nev->{'peer'} = $peer;
  $nev->{'peerport'} = $peerport if $peerport;
  BSServerEvents::reply(@reply) if @reply;
  $gev = $nev;	# switch to new event
  if ($nev->{'conf'}->{'setkeepalive'}) {
    setsockopt($nev->{'fd'}, SOL_SOCKET, SO_KEEPALIVE, pack("l",1));
  }
  return $nev;
}

sub stream_close {
  my ($ev, $wev, $err, $werr) = @_;
  if ($ev) {
    print "$err\n" if $err;
    BSEvents::rem($ev) if $ev->{'fd'} && !$ev->{'paused'};
    $ev->{'closehandler'}->($ev, $err) if $ev->{'closehandler'};
    close $ev->{'fd'} if $ev->{'fd'};
    delete $ev->{'fd'};
    delete $ev->{'writeev'};
  }
  if ($wev) {
    print "$werr\n" if $werr;
    BSEvents::rem($wev) if $wev->{'fd'} && !$wev->{'paused'};
    $wev->{'closehandler'}->($wev, $werr) if $wev->{'closehandler'};
    close $wev->{'fd'} if $wev->{'fd'};
    delete $wev->{'fd'};
    delete $wev->{'readev'};
  }
}

#
# read from a file descriptor (socket or file)
# - convert to chunks if 'makechunks'
# - put data into write event
# - do flow control
#

sub stream_read_handler {
  my ($ev) = @_;
  #print "stream_read_handler $ev\n";
  my $wev = $ev->{'writeev'};
  $wev->{'replbuf'} = '' unless exists $wev->{'replbuf'};
  my $r;
  if ($ev->{'fd'}) {
    if ($ev->{'makechunks'}) {
      my $b = '';
      $r = sysread($ev->{'fd'}, $b, 4096);
      $wev->{'replbuf'} .= sprintf("%X\r\n", length($b)).$b."\r\n" if $r;
    } else {
      $r = sysread($ev->{'fd'}, $wev->{'replbuf'}, 4096, length($wev->{'replbuf'}));
    }
    if (!defined($r)) {
      if ($! == POSIX::EINTR || $! == POSIX::EWOULDBLOCK) {
        BSEvents::add($ev);
        return;
      }
      print "stream_read_handler: $!\n";
      # can't do much here, fallthrough in EOF code
    }
  }
  if (!$r) {
#    print "stream_read_handler: EOF\n";
    if ($ev->{'eofhandler'}) {
      close $ev->{'fd'} if $ev->{'fd'};
      delete $ev->{'fd'};
      my $data = $ev->{'eofhandler'}->($ev);
      if (defined($data) && $data ne '') {
        if ($ev->{'makechunks'}) {
	  # keep those chunks small, otherwise our receiver will choke
          while (length($data) > 4096) {
	    my $d = substr($data, 0, 4096);
            $wev->{'replbuf'} .= sprintf("%X\r\n", length($d)).$d."\r\n";
	    $data = substr($data, 4096);
          }
          $wev->{'replbuf'} .= sprintf("%X\r\n", length($data)).$data."\r\n";
	} else {
          $wev->{'replbuf'} .= $data;
	}
      }
      if ($ev->{'fd'}) {
        stream_read_handler($ev);	# redo with new fd
        return;
      }
    }
    $wev->{'replbuf'} .= "0\r\n\r\n" if $ev->{'makechunks'};
    $ev->{'eof'} = 1;
    $ev->{'closehandler'}->($ev) if $ev->{'closehandler'};
    close $ev->{'fd'} if $ev->{'fd'};
    delete $ev->{'fd'};
    if ($wev && $wev->{'paused'}) {
      if (length($wev->{'replbuf'})) {
        delete $wev->{'paused'};
        BSEvents::add($wev)
      } else {
        stream_close($ev, $wev);
      }
    }
    return;
  }
  if ($wev->{'paused'}) {
    delete $wev->{'paused'};
    BSEvents::add($wev);
    # check if add() killed us
    return unless $ev->{'fd'};
  }
  if (length($wev->{'replbuf'}) >= 16384) {
    #print "write buffer too full, throttle\n";
    $ev->{'paused'} = 1;
  }
  BSEvents::add($ev) unless $ev->{'paused'};
}

#
# write to a file descriptor (socket)
# - do flow control
#

sub stream_write_handler {
  my ($ev) = @_;
  my $rev = $ev->{'readev'};
  #print "stream_write_handler $ev (rev=$rev)\n";
  my $l = length($ev->{'replbuf'});
  return unless $l;
  $l = 4096 if $l > 4096;
  my $r = syswrite($ev->{'fd'}, $ev->{'replbuf'}, $l);
  if (!defined($r)) {
    if ($! == POSIX::EINTR || $! == POSIX::EWOULDBLOCK) {
      BSEvents::add($ev);
      return;
    }
    print "stream_write_handler: $!\n";
    $ev->{'paused'} = 1;
    # support multiple writers ($ev will be a $jev in that case)
    if ($rev->{'writeev'} != $ev) {
      # leave reader open
      print "reader stays open\n";
      stream_close(undef, $ev);
    } else {
      stream_close($rev, $ev);
    }
    return;
  }
  $ev->{'replbuf'} = substr($ev->{'replbuf'}, $r) if $r;
  # flow control: have we reached the low water mark?
  if ($rev->{'paused'} && length($ev->{'replbuf'}) <= 8192) {
    delete $rev->{'paused'};
    BSEvents::add($rev);
    if ($rev->{'writeev'} != $ev) {
      my $wev = $rev->{'writeev'};
      if ($wev->{'paused'} && length($wev->{'replbuf'})) {
	#print "pushing old data\n";
	delete $wev->{'paused'};
	BSEvents::add($wev);
      }
    }
  }
  if (length($ev->{'replbuf'})) {
    BSEvents::add($ev);
  } else {
    $ev->{'paused'} = 1;
    stream_close($rev, $ev) if $rev->{'eof'};
  }
}

sub periodic_handler {
  my ($ev) = @_;
  my $conf = $ev->{'conf'};
  return unless $conf->{'periodic'};
  $conf->{'periodic'}->($conf);
  BSEvents::add($ev, $conf->{'periodic_interval'} || 3) if $conf->{'periodic'};
}

sub addserver {
  my ($fd, $conf) = @_;
  my $sockev = BSEvents::new('read', \&newconnect);
  $sockev->{'fd'} = $fd;
  $sockev->{'conf'} = $conf;
  BSEvents::add($sockev);
  if ($conf->{'periodic'}) {
    my $per_ev = BSEvents::new('timeout', \&periodic_handler);
    $per_ev->{'conf'} = $conf;
    BSEvents::add($per_ev, $conf->{'periodic_interval'} || 3);
  }
  return $sockev;
}

1;
