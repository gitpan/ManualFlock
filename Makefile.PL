use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'File::ManualFlock',
    'VERSION_FROM'	=> 'ManualFlock.pm', # finds $VERSION
    'PREREQ_PM'		=> { Fcntl => 0, 
                       File::stat => 0,
                       File::Basename => 0,
                       DirHandle => 0,
                       FileHandle => 0,
                       File::ManualFlock::Constants => 0
                     }, # e.g., Module::Name => 1.1
                     
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'ManualFlock.pm', # retrieve abstract from module
       AUTHOR     => 'A. U. Thor <a.u.thor@a.galaxy.far.far.away>') : ()),
);
