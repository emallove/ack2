package App::Ack;

use warnings;
use strict;

use App::Ack::ConfigFinder;
use Getopt::Long;
use File::Next 0.40;

=head1 NAME

App::Ack - A container for functions for the ack program

=head1 VERSION

Version 2.00a01

=cut

our $VERSION;
our $COPYRIGHT;
BEGIN {
    $VERSION = '2.00a01';
    $COPYRIGHT = 'Copyright 2005-2011 Andy Lester.';
}

our $fh;

BEGIN {
    $fh = *STDOUT;
}


our %types;
our %type_wanted;
our %mappings;
our %ignore_dirs;

our $is_filter_mode;
our $output_to_pipe;

our $dir_sep_chars;
our $is_cygwin;
our $is_windows;

use File::Spec ();
use File::Glob ':glob';
use Getopt::Long ();

BEGIN {
    # These have to be checked before any filehandle diddling.
    $output_to_pipe  = not -t *STDOUT;
    $is_filter_mode = -p STDIN;

    $is_cygwin       = ($^O eq 'cygwin');
    $is_windows      = ($^O =~ /MSWin32/);
    $dir_sep_chars   = $is_windows ? quotemeta( '\\/' ) : quotemeta( File::Spec->catfile( '', '' ) );
}

=head1 SYNOPSIS

If you want to know about the F<ack> program, see the F<ack> file itself.

No user-serviceable parts inside.  F<ack> is all that should use this.

=head1 FUNCTIONS

=head2 read_ackrc

Reads the contents of the .ackrc file and returns the arguments.

=cut

sub retrieve_arg_sources {
    my @arg_sources;

    my $noenv;
    my $ackrc;

    Getopt::Long::Configure('default');
    Getopt::Long::Configure('pass_through');
    Getopt::Long::Configure('no_auto_abbrev');

    GetOptions(
        'noenv'   => \$noenv,
        'ackrc=s' => \$ackrc,
    );

    Getopt::Long::Configure('default');

    my @files;

    if ( !$noenv ) {
        my $finder = App::Ack::ConfigFinder->new;
        @files  = $finder->find_config_files;
    }
    if ( $ackrc ) {
        # we explicitly use open so we get a nice error message
        # XXX this is a potential race condition!
        if(open my $fh, '<', $ackrc) {
            close $fh;
        } else {
            die "Unable to load ackrc '$ackrc': $!"
        }
        push( @files, $ackrc );
    }

    foreach my $file ( @files) {
        my @lines = read_rcfile($file);
        push ( @arg_sources, $file, \@lines ) if @lines;
    }

    if ( $ENV{ACK_OPTIONS} && !$noenv ) {
        push( @arg_sources, 'ACK_OPTIONS' => $ENV{ACK_OPTIONS} );
    }

    push( @arg_sources, 'ARGV' => [ @ARGV ] );

    return @arg_sources;
}

sub read_rcfile {
    my $file = shift;

    return unless defined $file && -e $file;

    my @lines;

    open( my $fh, '<', $file ) or App::Ack::die( "Unable to read $file: $!" );
    while ( my $line = <$fh> ) {
        chomp $line;
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;

        next if $line eq '';
        next if $line =~ /^#/;

        push( @lines, $line );
    }
    close $fh;

    return @lines;
}

=head2 create_ignore_rules( $what, $where, \@opts )

Takes an array of options passed in on the command line and returns
a hashref of information about them:

* 
# is:  Match the filename exactly
# ext: Match the extension
# regex: Match against a Perl regular expression

=cut

sub create_ignore_rules {
    my $what  = shift;
    my $where = shift;
    my $opts  = shift;

    my @opts = @{$opts};

    my %rules = {
    };

    for my $opt ( @opts ) {
        if ( $opt =~ /^(is|ext|regex),(.+)$/ ) {
            my $method = $1;
            my $arg    = $2;
            if ( $method eq 'regex' ) {
                push( @{$rules{regex}}, qr/$arg/ );
            }
            else {
                ++$rules{$method}{$arg};
            }
        }
        else {
            App::Ack::die( "Invalid argument for --$what: $opt" );
        }
    }

    return \%rules;
}

=head2 remove_dir_sep( $path )

This functions removes a trailing path separator, if there is one, from its argument

=cut

sub remove_dir_sep {
    my $path = shift;
    $path =~ s/[$dir_sep_chars]$//;

    return $path;
}

=head2 build_regex( $str, \%opts )

Returns a regex object based on a string and command-line options.

Dies when the regex $str is undefinied (i.e. not given on command line).

=cut

sub build_regex {
    my $str = shift;
    my $opt = shift;

    defined $str or App::Ack::die( 'No regular expression found.' );

    $str = quotemeta( $str ) if $opt->{Q};
    if ( $opt->{w} ) {
        $str = "\\b$str" if $str =~ /^\w/;
        $str = "$str\\b" if $str =~ /\w$/;
    }

    my $regex_is_lc = $str eq lc $str;
    if ( $opt->{i} || ($opt->{smart_case} && $regex_is_lc) ) {
        $str = "(?i)$str";
    }

    return $str;
}

=head2 check_regex( $regex_str )

Checks that the $regex_str can be compiled into a perl regular expression.
Dies with the error message if this is not the case.

No return value.

=cut

sub check_regex {
    my $regex = shift;

    return unless defined $regex;

    eval { qr/$regex/ };
    if ($@) {
        (my $error = $@) =~ s/ at \S+ line \d+.*//;
        chomp($error);
        App::Ack::die( "Invalid regex '$regex':\n  $error" );
    }

    return;
}



=head2 warn( @_ )

Put out an ack-specific warning.

=cut

sub warn { ## no critic (ProhibitBuiltinHomonyms)
    return CORE::warn( _my_program(), ': ', @_, "\n" );
}

=head2 die( @_ )

Die in an ack-specific way.

=cut

sub die { ## no critic (ProhibitBuiltinHomonyms)
    return CORE::die( _my_program(), ': ', @_, "\n" );
}

sub _my_program {
    require File::Basename;
    return File::Basename::basename( $0 );
}


=head2 filetypes_supported()

Returns a list of all the types that we can detect.

=cut

sub filetypes_supported {
    return keys %mappings;
}

sub _get_thpppt {
    my $y = q{_   /|,\\'!.x',=(www)=,   U   };
    $y =~ tr/,x!w/\nOo_/;
    return $y;
}

sub _thpppt {
    my $y = _get_thpppt();
    App::Ack::print( "$y ack $_[0]!\n" );
    exit 0;
}

=head2 show_help()

Dumps the help page to the user.

=cut

sub show_help {
    my $help_arg = shift || 0;

#   return show_help_types() if $help_arg =~ /^types?/;

    App::Ack::print( <<"END_OF_HELP" );
Usage: ack [OPTION]... PATTERN [FILE]

Search for PATTERN in each source file in the tree from cwd on down.
If [FILES] is specified, then only those files/directories are checked.
ack may also search STDIN, but only if no FILE are specified, or if
one of FILES is "-".

Default switches may be specified in ACK_OPTIONS environment variable or
an .ackrc file. If you want no dependency on the environment, turn it
off with --noenv.

Example: ack -i select

Searching:

Search output:

File presentation:

File finding:

File inclusion/exclusion:

Miscellaneous:
  --noenv               Ignore environment variables and global ackrc files
  --ackrc=filename      Specify an ackrc file to use
  --help                This help
  --man                 Man page
  --version             Display version & copyright
  --thpppt              Bill the Cat

Exit status is 0 if match, 1 if no match.

This is version $VERSION of ack.
END_OF_HELP

    return;
 }


=head2 show_help_types()

Display the filetypes help subpage.

=cut

sub show_help_types {
    App::Ack::print( <<'END_OF_HELP' );
Usage: ack [OPTION]... PATTERN [FILES]

The following is the list of filetypes supported by ack.  You can
specify a file type with the --type=TYPE format, or the --TYPE
format.  For example, both --type=perl and --perl work.

Note that some extensions may appear in multiple types.  For example,
.pod files are both Perl and Parrot.

END_OF_HELP

    my @types = filetypes_supported();
    my $maxlen = 0;
    for ( @types ) {
        $maxlen = length if $maxlen < length;
    }
    for my $type ( sort @types ) {
        next if $type =~ /^-/; # Stuff to not show
        my $ext_list = $mappings{$type};

        if ( ref $ext_list ) {
            $ext_list = join( ' ', map { ".$_" } @{$ext_list} );
        }
        App::Ack::print( sprintf( "    --[no]%-*.*s %s\n", $maxlen, $maxlen, $type, $ext_list ) );
    }

    return;
}

sub _listify {
    my @whats = @_;

    return '' if !@whats;

    my $end = pop @whats;
    my $str = @whats ? join( ', ', @whats ) . " and $end" : $end;

    no warnings 'once';
    require Text::Wrap;
    $Text::Wrap::columns = 75;
    return Text::Wrap::wrap( '', '    ', $str );
}

=head2 get_version_statement

Returns the version information for ack.

=cut

sub get_version_statement {
    require Config;

    my $copyright = get_copyright();
    my $this_perl = $Config::Config{perlpath};
    if ($^O ne 'VMS') {
        my $ext = $Config::Config{_exe};
        $this_perl .= $ext unless $this_perl =~ m/$ext$/i;
    }
    my $ver = sprintf( '%vd', $^V );

    return <<"END_OF_VERSION";
ack $VERSION
Running under Perl $ver at $this_perl

$copyright

This program is free software.  You may modify or distribute it
under the terms of the Artistic License v2.0.
END_OF_VERSION
}

=head2 print_version_statement

Prints the version information for ack.

=cut

sub print_version_statement {
    App::Ack::print( get_version_statement() );

    return;
}

=head2 get_copyright

Return the copyright for ack.

=cut

sub get_copyright {
    return $COPYRIGHT;
}

=head2 load_colors

Set default colors, load Term::ANSIColor

=cut

sub load_colors {
    eval 'use Term::ANSIColor ()';

    $ENV{ACK_COLOR_MATCH}    ||= 'black on_yellow';
    $ENV{ACK_COLOR_FILENAME} ||= 'bold green';
    $ENV{ACK_COLOR_LINENO}   ||= 'bold yellow';

    return;
}


# print subs added in order to make it easy for a third party
# module (such as App::Wack) to redefine the display methods
# and show the results in a different way.
sub print                   { print {$fh} @_ }
sub print_first_filename    { App::Ack::print( $_[0], "\n" ) }
sub print_blank_line        { App::Ack::print( "\n" ) }
sub print_separator         { App::Ack::print( "--\n" ) }
sub print_filename          { App::Ack::print( $_[0], $_[1] ) }
sub print_line_no           { App::Ack::print( $_[0], $_[1] ) }
sub print_column_no         { App::Ack::print( $_[0], $_[1] ) }
sub print_count {
    my $filename = shift;
    my $nmatches = shift;
    my $ors = shift;
    my $count = shift;
    my $show_filename = shift;

    if ($show_filename) {
        App::Ack::print( $filename );
        App::Ack::print( ':', $nmatches ) if $count;
    }
    else {
        App::Ack::print( $nmatches ) if $count;
    }
    App::Ack::print( $ors );
}

sub print_count0 {
    my $filename = shift;
    my $ors = shift;
    my $show_filename = shift;

    if ($show_filename) {
        App::Ack::print( $filename, ':0', $ors );
    }
    else {
        App::Ack::print( '0', $ors );
    }
}

sub set_up_pager {
    my $command = shift;

    return if App::Ack::output_to_pipe();

    my $pager;
    if ( not open( $pager, '|-', $command ) ) {
        App::Ack::die( qq{Unable to pipe to pager "$command": $!} );
    }
    $fh = $pager;

    return;
}

=head2 output_to_pipe()

Returns true if ack's input is coming from a pipe.

=cut

sub output_to_pipe {
    return $output_to_pipe;
}

=head2 exit_from_ack

Exit from the application with the correct exit code.

Returns with 0 if a match was found, otherwise with 1. The number of matches is
handed in as the only argument.

=cut

sub exit_from_ack {
    my $nmatches = shift;

    my $rc = $nmatches ? 0 : 1;
    exit $rc;
}

sub process_matches {
    my ( $resource, $opt, $func ) = @_;

    my $re             = $opt->{regex};
    my $nmatches       = 0;
    my $invert         = $opt->{v};
    my $after_context  = $opt->{after_context};
    my $before_context = $opt->{before_context};

    App::Ack::iterate($resource, $opt, sub {
        if($invert ? !/$re/ : /$re/) {
            $nmatches++;

            my $matching_line = $_;

            return 0 if $func && !$func->($matching_line);
        }
        return 1;
    });

    return $nmatches;
}

sub print_matches_in_resource {
    my ( $resource, $opt ) = @_;

    my $print_filename = $opt->{H} && !$opt->{h};

    my $max_count           = $opt->{m} || -1;
    my $ors                 = $opt->{print0} ? "\0" : "\n";
    my $color               = $opt->{color};
    my $match_word          = $opt->{w};
    my $re                  = $opt->{regex};
    my $last_printed        = -1;
    my $is_first_match      = 1;
    my $is_tracking_context = $opt->{after_context} || $opt->{before_context};

    return process_matches($resource, $opt, sub {
        my ( $matching_line ) = @_;

        chomp $matching_line;

        my $filename = $resource->name;
        my $line_no  = $.; # XXX should we pass $. in?

        my ( $before_context, $after_context ) = get_context();

        if($before_context) {
            my $first_line = $. - @{$before_context};
            if( !$is_first_match && $last_printed != $first_line - 1 ) {
                if( $first_line == 10 ) {
                    print $last_printed, ' ', $first_line, "\n";
                }
                App::Ack::print('--', $ors);
            }
            $last_printed = $.; # XXX unless --after-context
            my $offset = @{$before_context};
            foreach my $line (@{$before_context}) {
                chomp $line;
                App::Ack::print_line_with_options($opt, $filename, $line, $. - $offset, '-');
                $last_printed = $. - $offset;
                $offset--;
            }
        }

        if( $is_tracking_context && !$is_first_match && $last_printed != $. - 1 ) {
            App::Ack::print('--', $ors);
        }

        if($color) {
            $filename = Term::ANSIColor::colored($filename,
                $ENV{ACK_COLOR_FILENAME});
            $line_no  = Term::ANSIColor::colored($line_no,
                $ENV{ACK_COLOR_LINENO});
        }

        if(@- > 1) {
            my $offset = 0; # additional offset for when we add stuff

            for(my $i = 1; $i < @-; $i++) {
                my $match_start = $-[$i];
                my $match_end   = $+[$i];

                my $substring = substr( $matching_line,
                    $offset + $match_start, $match_end - $match_start );
                my $substitution = Term::ANSIColor::colored( $substring,
                    $ENV{ACK_COLOR_MATCH} );

                substr( $matching_line, $offset + $match_start,
                    $match_end - $match_start, $substitution );

                $offset += length( $substitution ) - length( $substring );
            }
        }
        elsif($color) {
            # XXX I know $& is a no-no; fix it later
            $matching_line  =~ s/$re/Term::ANSIColor::colored($&, $ENV{ACK_COLOR_MATCH})/ge;
            $matching_line .= "\033[0m\033[K";
        }

        App::Ack::print_line_with_options($opt, $filename, $matching_line, $line_no, ':');
        $last_printed = $.;

        if($after_context) {
            my $offset = 1;
            foreach my $line (@{$after_context}) {
                chomp $line;
                App::Ack::print_line_with_options($opt, $filename, $line, $. + $offset, '-');
                $last_printed = $. + $offset;
                $offset++;
            }
        }

        $is_first_match = 0;
        return --$max_count != 0;
    });
}

sub count_matches_in_resource {
    my ( $resource, $opt ) = @_;

    return process_matches($resource, $opt);
}

sub resource_has_match {
    my ( $resource, $opt ) = @_;

    local $opt->{v} = 0;

    return count_matches_in_resource($resource, $opt) > 0;
}

{

my @before_ctx_lines;
my @after_ctx_lines;
my $is_iterating;

sub get_context {
    unless( $is_iterating ) {
        Carp::croak("get_context() called outside of iterate()");
    }

    return (
        scalar(@before_ctx_lines) ? \@before_ctx_lines : undef,
        scalar(@after_ctx_lines)  ? \@after_ctx_lines  : undef,
    );
}

sub iterate {
    my ( $resource, $opt, $cb ) = @_;

    $is_iterating = 1;

    my $n_before_ctx_lines = $opt->{before_context} || 0;
    my $n_after_ctx_lines  = $opt->{after_context}  || 0;
    my $current_line;

    @after_ctx_lines = @before_ctx_lines = ();

    if($resource->next_text()) {
        $current_line = $_; # prime the first line of input
    }

    while(defined $current_line) {
        while(@after_ctx_lines < $n_after_ctx_lines && $resource->next_text()) {
            push @after_ctx_lines, $_;
        }

        local $_ = $current_line;
        local $. = $. - @after_ctx_lines;

        last unless $cb->();

        push @before_ctx_lines, $current_line;

        if($n_after_ctx_lines) {
            $current_line = shift @after_ctx_lines;
        }
        elsif($resource->next_text()) {
            $current_line = $_;
        }
        else {
            undef $current_line;
        }
        shift @before_ctx_lines while @before_ctx_lines > $n_before_ctx_lines;
    }

    $is_iterating = 0;
}

}

sub print_line_with_options {
    my ( $opt, $filename, $line, $line_no, $separator ) = @_;

    my $print_filename = $opt->{H} && !$opt->{h};
    my $ors            = $opt->{print0} ? "\0" : "\n";

    my @line_parts;

    if($print_filename) {
        push @line_parts, $filename, $line_no;
    }
    push @line_parts, $line;
    App::Ack::print( join( $separator, @line_parts ), $ors );
}

my $last_line_printed;

BEGIN {
    $last_line_printed = 0;
}

sub print_line_with_context {
    my ( $opt, $filename, $line, $line_no ) = @_;

    my $ors = $opt->{print0} ? "\0" : "\n";

    my ( $before_context, $after_context ) = App::Ack::get_context();

    if($before_context) {
        my $before_line_no = $line_no - @{$before_context};

        if($last_line_printed != $before_line_no - 1) {
            App::Ack::print('--', $ors);
        }

        foreach my $before_line (@{$before_context}) {
            chomp $before_line;
            App::Ack::print_line_with_options($opt, $filename, $before_line, $before_line_no, '-');
            $last_line_printed = $before_line_no;
            $before_line_no++;
        }
    }

    if($after_context && $last_line_printed != $line_no - 1) {
        App::Ack::print('--', $ors);
    }

    App::Ack::print_line_with_options($opt, $filename, $line, $line_no, ':');

    $last_line_printed = $line_no;

    if($after_context) {
        my $after_line_no = $line_no + 1;

        foreach my $line (@{$after_context}) {
            chomp $line;
            App::Ack::print_line_with_options($opt, $filename, $line, $after_line_no, '-');
            $last_line_printed = $after_line_no;
            $after_line_no++;
        }
    }
}

=head1 COPYRIGHT & LICENSE

Copyright 2005-2011 Andy Lester.

This program is free software; you can redistribute it and/or modify
it under the terms of the Artistic License v2.0.

=cut

1; # End of App::Ack
