use 5.008001;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'Mail::Postini',
    VERSION_FROM      => 'lib/Mail/Postini.pm', # finds $VERSION
    PREREQ_PM         => { LWP::UserAgent => 2.0,
                           URI::Escape => 3.20,
                           Digest::SHA1 => 2.10,
                         },
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Mail/Postini.pm', # retrieve abstract from module
       AUTHOR         => 'Scott Wiersdorf <scott@perlcode.org>') : ()),
);
