package File::ManualFlock;
#===================================================================#

#======================================#
# Version Info                         #
#===================================================================#

$File::ManualFlock::VERSION = '1.0.0';

#======================================#
# Dependencies                         #
#===================================================================#

#--------------------------------------#
# Standard Dependencies

use 5.006;
use strict;
use warnings;
use vars qw($rec_flag);

#--------------------------------------#
# Programmatic Dependencies

use Fcntl;
use File::stat;
use File::Basename;
use DirHandle;
use FileHandle;

#--------------------------------------#
# Constants

use File::ManualFlock::Constants;

#======================================#
# Inheritance                          #
#===================================================================#

#======================================#
# Public Methods                       #
#===================================================================#

#print "mflock: lock_sh: " . LOCK_SH;
local %File::ManualFlock::mflocks = {};

#--------------------------------------#
# Constructor

sub new
{
  my $pkg = shift;
  my $self = {};
  bless $self, $pkg;
  #print "\n----new ob: $self\n\n";
  return $self;
}

#-------------------------------------------------------------------#

sub mflock
{
  
  # construct new ob unless mode == 8 or 12 (unlock)
  # call _mflock on new ob
  # return ref to new ob
  
  my @params = @_;
  if ( ( $params[2] == 8 ) || ( $params[2] == 12) )
  {
    my $self = shift @params;
    $self->{'last_result'} = $self->free_lock;
  }
  else
  {
    shift @params;
    my $pkg = __PACKAGE__;
    my $self = {};
    bless $self, $pkg;
    $self->{'last_result'} = $self->_mflock( @params );
    #print "\n----mflock ob: $self\n\n";
    return $self;
  }
}
  
#-------------------------------------------------------------------#

sub free_lock 
{ 
  my $self = shift;
  #print "\n\n----free block start\n";
  #print "ob: $self->{sf}\n";
  my $ul = undef;
  foreach my $mfl ( keys %{$File::ManualFlock::mflocks{$self->{sf}}} )
  { 
    if ( -f $mfl )
    { 
      my $mfl_fh = $File::ManualFlock::mflocks{$self->{sf}}->{$mfl};
      close $mfl_fh;
      $ul = unlink $mfl;
      #print "  -- $ul unlinked --\n";
      $self->_unregister_mflock( $mfl );
      #print "  -- unregistered --\n";
    }
  }
  #print "\n----free block ran\n\n";
  return $ul;
}

#======================================#
# Private Methods                      #
#===================================================================#

sub _mflock
{
  my $self = shift;
  my ( $filepath, $open_mode, $max_wait, $expire ) = @_;

  if ( !( defined $filepath ) ) { die "No filepath specified for locking. $!"; }
  $open_mode = $open_mode || (LOCK_SH|LOCK_NB);
  
  if ( $max_wait == 0 ) { $max_wait = undef; }
  $max_wait = $max_wait || undef;
  if ( $expire == 0 ) { $expire = undef; }
  $expire = $expire || 3600;
  
  # we need stack frame count for naming purposes
  # so we don't clobber values in %File::ManualFlock::mflocks
  # from other frames
  
  my $count = 0;
  while ( 1 )
  {
    my @call_stat = caller $count;
    my $caller_pack = $call_stat[0];
    last if ( $caller_pack ne __PACKAGE__ );
    $count++;
  }

  #--------------------------------------#
  # for recursive calling, we must store mflocks 
  # for different stack frames under separate
  # keys so they don't clobber each other;
  # declaring %File::ManualFlock::mflocks
  # local is not sufficient 
  
  $self->{sf} = "href_" . $self . "_frame_" . $count;
  $File::ManualFlock::mflocks{$self->{sf}} = {};

  #--------------------------------------#
  # $max_wait, if present, indicates blocking 
  # is ok and timeout length in seconds; if undef,
  # non-blocking
  
  #--------------------------------------#
  # $expire indicates age, in seconds since
  # modification time (based upon start of epoch),
  # at which to expire locks
  
  my ( $mfl_fh, $result ) = ();
  if ( $open_mode == 1 )
  {
    if ( !( defined $max_wait ) ) # (LOCK_SH)
    {
      $max_wait = -1; # infinite because non-blocking flag not set when $open_mode = 1
    }
    $result = $self->_get_sh_lock( $filepath, $max_wait, $expire );
  }
  elsif ( $open_mode == 2 ) # (LOCK_EX)
  {
    if ( !( defined $max_wait ) )
    {
      $max_wait = -1; # infinite because non-blocking flag not set when $open_mode = 2
    }
    $result = $self->_get_ex_lock( $filepath, $max_wait, $expire );
  }  
  elsif ( $open_mode == 5 ) # (LOCK_SH|LOCK_NB)
  {
    $max_wait = undef; # undef because non-blocking flag is set when $open_mode = 5
    $result = $self->_get_sh_lock( $filepath, $max_wait, $expire );
  }
  elsif ( $open_mode == 6 ) # (LOCK_EX|LOCK_NB)
  {
    $max_wait = undef; # undef because non-blocking flag is set when $open_mode = 5
    $result = $self->_get_ex_lock( $filepath, $max_wait, $expire );
  }
  elsif ( ( $open_mode == 8 ) || ( $open_mode == 12 ) ) # ((LOCK_UN)|{LOCK_NB})
  {
    $result = $self->free_lock;
  }    
  else
  {
    die "Invalid options given to mflock. $!";
  }
  
  #$rec_flag = $rec_flag + 1;
  #if ( $rec_flag < 0 )
  #{
  #  my $mflh = $self->_test_recursive_call;
  #} 
  
  return $result;
}

#-------------------------------------------------------------------#

sub _get_sh_lock 
{
  my $self = shift;
  my ( $filepath, $max_wait, $expire ) = @_;
  
  my $fh = new FileHandle;
  my $ex_fh = new FileHandle;
  my $sh_fh = new FileHandle;
  
  my $start_time = time;
  for (;;)
  {
    if ( sysopen( $ex_fh, "$filepath.ex.mflock", O_WRONLY | O_EXCL | O_CREAT ) )
    {
      
      $self->_register_mflock( "$filepath.ex.mflock", $ex_fh );

      #sleep 3;
      
      my $next_lock_num = undef;
      SH_LK: 
      for (;;)
      { 
        # get next lock_num while excl lock freezes other processes seeking locks
        $next_lock_num = $self->_get_next_sh_lock_num( $filepath );
        
        unless ( sysopen( $sh_fh, "$filepath.sh.$next_lock_num.mflock", O_RDONLY | O_EXCL | O_CREAT ) )
        {
          next SH_LK;
        }
        last SH_LK;
      }
      $self->_register_mflock( "$filepath.sh.$next_lock_num.mflock", $sh_fh );
      
      #sleep 3;
            
      #sysopen( $fh, $filepath, O_RDONLY );
      #binmode $fh;
      #autoflush $fh 1;
      
      #sleep 2;
            
      close $ex_fh;
      unlink "$filepath.ex.mflock";
      $self->_unregister_mflock( "$filepath.ex.mflock" );
      
      return( 1 );
    }
    else
    {
      # purge dir of expired locks
      
      my $ulcount = $self->_clear_expired_locks( $filepath, $expire );
    }
    
    my $sec_elapsed = time - $start_time;
    last unless ( ( $max_wait > $sec_elapsed ) || ( $max_wait == -1 ) );
  }
  
  return undef;
}

#-------------------------------------------------------------------#

sub _get_ex_lock
{
  my $self = shift;
  my ( $filepath, $max_wait, $expire ) = @_;
  
  my $fh = new FileHandle;
  my $ex_fh = new FileHandle;
  
  my $start_time = time;
  EX_LK:
  for (;;)
  {
    if ( sysopen( $ex_fh, "$filepath.ex.mflock", O_WRONLY | O_EXCL | O_CREAT ) )
    {  
      $self->_register_mflock( "$filepath.ex.mflock", $ex_fh );
      last EX_LK;
    }
    else
    {
      # purge dir of expired locks
      
      my $ulcount = $self->_clear_expired_locks( $filepath, $expire );
      #print "EX_LK: ulcount: $ulcount\n";
    }
    
    my $sec_elapsed = time - $start_time;
    last EX_LK unless ( ( $max_wait > $sec_elapsed ) || ( $max_wait == -1 ) );
  }

  # check for no sh locks
  # return(1) on success
  
  NO_SH_LK:
  for (;;)
  {
    if ( $self->_get_next_sh_lock_num( $filepath ) == 1 )
    {
      return( 1 );
    }
    else
    {
      # purge dir of expired locks
      my $ulcount = $self->_clear_expired_locks( $filepath, $expire );
    }
    
    my $sec_elapsed = time - $start_time;
    unless ( ( $max_wait > $sec_elapsed ) || ( $max_wait == -1 ) )
    {
      # release excl lock; exit loop;
      close $ex_fh;
      unlink "$filepath.ex.mflock";
      $self->_unregister_mflock( "$filepath.ex.mflock" );
      
      last NO_SH_LK;
    }
  }
  
  return undef;
}

#-------------------------------------------------------------------#

sub _get_next_sh_lock_num
{
  # scan directory; match sh file lock, parse for lock_num; sort for highest lock_num; return highest lock_num plus 1;
  my $self = shift;
  my $filepath = shift;  
  
  #my ($base, $path, $type) = fileparse( $fpath, qr{\.(ex|sh)\.\d*\.?(mflock)} );
  my ($base, $path ) = fileparse( $filepath );
  $path = $self->_chop_slash( $path );
  
    my $dh = DirHandle->new( $path )
    or die "Can't open $path: $!";
  # my @sh_mflocks = grep { m/\.(ex|sh)\.\d*\.?(mflock)/ } $dh->read;
  my @sh_mflocks = grep { m/\.(sh)\.\d+\.(mflock)/ } $dh->read;

  # now, get only the locks for the target file
  
  my @target_sh_mflocks = grep { m/^($base)/ } @sh_mflocks;
  
  # get lock_nums from sh mflock filenames
  my @lock_nums = ();
  foreach my $sh_mflock ( @target_sh_mflocks )
  {
    # get lock_num
    my $ext = $sh_mflock;
    $ext =~ /(\.(sh)\.\d+\.(mflock))$/;
    $ext = $1;
    my @parts = split /\./, $ext, 4;
    push @lock_nums, $parts[2];
  }
  
  # sort lock_nums to find highest number existing lock
  
  @lock_nums = sort {$a <=> $b} @lock_nums;
  my $newest_lock_num = pop @lock_nums;
  
  # get new lock num
  
  my $new_lock_num = $newest_lock_num + 1;

  return $new_lock_num;
}

#-------------------------------------------------------------------#
  
sub _register_mflock
{
  my $self = shift;
  my ( $mflock_filepath, $mflock_fh ) = @_;
  $File::ManualFlock::mflocks{$self->{sf}}->{ $mflock_filepath } = $mflock_fh;
}

#-------------------------------------------------------------------#

sub _unregister_mflock
{
  my $self = shift;
  my $mflock_filepath = shift;
  delete $File::ManualFlock::mflocks{$self->{sf}}->{ $mflock_filepath };
}

#-------------------------------------------------------------------#

sub _clear_expired_locks
{
  # called whenever we fail to get a lock, until timeout period expires
  my $self = shift;
  my ( $filepath, $exp ) = @_;
  
  if ( $exp == -1 ) { return 0; }
  
  my ( $base, $path ) = fileparse( $filepath );
  $path = $self->_chop_slash( $path );
  my $dh = DirHandle->new( $path ) or die "Can't open $path: $!";
  my @mflocks = grep { m/($base)\.(ex|sh)\.\d*\.?(mflock)/ } $dh->read;
  my $ul_count = 0;
  foreach my $lock_file ( @mflocks )
  { 
    my $lock_filepath = "$path/$lock_file";
    
    my $st = stat $lock_filepath;
    my $mtime = $st->mtime if ( defined $st );
    my $file_age = (time - $mtime);
    if ( ( -f $lock_filepath ) && ( $file_age > $exp ) )
    {
      $ul_count = $ul_count + ( unlink $lock_filepath );
    }    
  }
  return $ul_count;  
}

#-------------------------------------------------------------------#

sub _chop_slash
{
  my ($self, $path) = @_;
  while(1)
  { 
    if ( $path =~ m|[ \\\/]+$| )
    {
      chop $path;
    }
    else
    {
      last;
    }  
  }
  
  return $path;
}

#-------------------------------------------------------------------#

# test sub; not used in production
sub _test_recursive_call
{
  my $self = shift;
  my $mf = new File::ManualFlock;

  my $filepath = 'I:/PerlProjects/fusdev/test_code/cgi-bin-tests/locks/mfl_test_recursive.pid';
  my $mfl_fh = $mf->mflock( $filepath, LOCK_SH )
   or die;
  return $mfl_fh;
 
}

#-------------------------------------------------------------------#

DESTROY 
{ 
  my $self = shift;
  #print "\n\n----destroy block start\n";
  #print "ob: $self->{sf}\n";
  
  foreach my $mfl ( keys %{$File::ManualFlock::mflocks{$self->{sf}}} )
  { 
    if ( -f $mfl )
    { 
      my $mfl_fh = $File::ManualFlock::mflocks{$self->{sf}}->{$mfl};
      close $mfl_fh;
      my $ul = unlink $mfl;
      #print "  -- $ul unlinked --\n";
      $self->_unregister_mflock( $mfl );
      #print "  -- unregistered --\n";
    }
  }
  #print "\n----destroy block ran\n\n";
}

#======================================#
# pod                                  #
#===================================================================#

=item 

=head1 NAME

File::ManualFlock - manual file locking for systems without flock (Win95/98/??);
               uses sysopen exclusively to establish and maintain locks

=head1 SYNOPSIS
    
    use File::ManualFlock;
    
    my $mfl = new File::ManualFlock;
    
    my $lh = $mfl->mflock( $filepath, $flags, $max_wait, $expire );
    
    my $lh = $mfl->free_lock;
    
    my $lh2 = $mfl->mflock( $filepath2, $flags2, $max_wait2, $expire2 );
    
    Note: You must assign the returned lock handle to a variable in the scope from which you
          make the call (e.g. $lh).  If you do not do so, the returned lock handle will
          immediately go out of scope and therewith release the lock on the file. You
          can also manually release a lock by calling the $lh->free_lock method on the 
          lock handle. Otherwise, all locks are released upon the lock handle going
          out of scope, or upon program termination, whichever occurs first.
          
          The $expire parameter, if utilized, must be given a value == -1 or >= 1.
          A 0 value will be treated as undef.  $expire specifies the permissable maximum
          age in seconds for a lock file.  Lock files older than $expire are forced released.
          To specify that locks should never be expired (i.e., they can exist for an infinite
          period), set $expire to -1 or MFL_INFINITE. If $expire is not specified, a lock
          will be forced released if it is older than 3600 seconds by default. Support for
          the $expire parameter means that "old" locks can be clobbered.  You cannot presently 
          enforce the expire time as a lock setter, but you can clobber old locks as a lock
          getter.
                    
          $flags can be:
          
          LOCK_SH
          LOCK_EX
          LOCK_UN
          LOCK_SH|LOCK_NB
          LOCK_EX|LOCK_NB
          LOCK_UN|LOCK_NB
          
          By default, LOCK_SH, LOCK_EX, and LOCK_UN block infinitely unless the parameter
          $max_wait >= 1 or $max_wait == undef or 0.  Set $max_wait == -1 or MFL_INFINITE 
          to block forever or until lock can be set.
          
          Where both the LOCK_NB flag is specified and $max_wait != 0, LOCK_NB trumps 
          $max_wait and $max_wait is set to undef.  

=head1 DESCRIPTION

This module provides an advisory file locking mechanism to allow
reliable file locking protections on systems without the standard
flock function.  This solution only relies upon sysopen  to achieve 
file locking, and is therefore more portable, although probably less
efficient, than the standard flock function.  The File::ManualFlock::mflock()
method supports exclusive, shared, blocking, and non-blocking file
locking.

The File::ManualFlock::Tools module provides "safe" file management tools that
employ and detect the mflock file locking mechanism.  They are basically
the standard tools wrapped with mflock file locking protections.

Mflock, like flock, is an advisory locking mechanism.  Mflock can be
used as a substitute for flock, but it will not detect files locked
with flock.  Likewise, flock will not detect files locked with mflock.  
Thus, while File::ManualFlock::FlockOverride offers a 'flock'
function that when used will override the standard flock and provide
the same interface, the two locking methods cannot be used
interchangeably. You must choose one or the other and go with it.

=head1 NOTES

Where both the LOCK_NB flag and $max_wait parameter are provided, LOCK_NB will
trump $max_wait and $max_wait will be set to undef.  Where $expire is not set,
locks will be considered expired if they are over 3600 seconds (1 hour) old, as
determined by the files mtime, given by the built-in stat function, and the 
number of seconds since the last epoch.  This should be ok with mod_perl, although
its not tested and other issues may be present. 

Note: you cannot enforce an expire date on your locks that others must respect.
If another programmer wants all locks for a file over 5 minutes old to be cleared,
they will be able to do that by setting $expire to 300.  In other words, support for
the $expire parameter means that "old" locks can be clobbered.  You cannot presently 
enforce the expire time as a lock setter, but you can clobber old locks as a lock
getter.

For the curious, here's how it works internally.  Exclusive locks are 
regulated by sysopen. See sysopen docs for details.

- readable excl(usive) locks are permitted when:
    1) no readable or writeable excl locks exist for the target file
    
- shared locks are permitted on a file when:
    1) a readable excl lock is available for the file

- writable excl locks are permitted on a file when:
    1) an excl lock is available for the file, and
    2) no shared locks remain on the file

- to get a shared lock on a file:
    1) get a readable excl lock on the file, and
    2) get a new shared lock on the file, and
    3) release the readable excl lock

- to get a writable excl lock:
    1) get a writable excl lock on a file
    2) check for any shared locks
    3) if blocking is permitted, wait until all shared locks are released
    4) hold the writable excl lock and proceed

Since there must be a way to clean up zombie locks following crashes, 
power failures, etc., locks are assumed to be zombies after a certain period.
By default, this period is one hour, or 3600 seconds from the files mtime,
as given by stat.  Using the mtime rather than the ctime allows renewing of
locks, although this feature is not yet implemented.

=head1 TODO
  
- force lock - useful for when you want to extend the life of a lock you own;
    otherwise, not safe to force lock; nearly the same result can presently be achieved
    by as setting $expire to 1 and $max_wait to 3 or so.

=head1 LICENSE

Same as Perl.

=head1 AUTHOR

Bill Catlan, E<lt>wcatlan@cpan.orgE<gt>
=cut

#===================================================================#
1;
