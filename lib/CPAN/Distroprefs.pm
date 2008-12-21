# -*- Mode: cperl; coding: utf-8; cperl-indent-level: 4 -*-
# vim: ts=4 sts=4 sw=4:

use strict;
package CPAN::Distroprefs;

use vars qw($VERSION);
$VERSION = '6';

package CPAN::Distroprefs::Result;

use File::Spec;

sub new { bless $_[1] || {} => $_[0] }

sub abs { File::Spec->catfile($_[0]->dir, $_[0]->file) }

sub __cloner {
    my ($class, $name, $newclass) = @_;
    $newclass = 'CPAN::Distroprefs::Result::' . $newclass;
    no strict 'refs';
    *{$class . '::' . $name} = sub {
        $newclass->new({
            %{ $_[0] },
            %{ $_[1] },
        });
    };
}
BEGIN { __PACKAGE__->__cloner(as_warning => 'Warning') }
BEGIN { __PACKAGE__->__cloner(as_fatal   => 'Fatal') }
BEGIN { __PACKAGE__->__cloner(as_success => 'Success') }

sub __accessor {
    my ($class, $key) = @_;
    no strict 'refs';
    *{$class . '::' . $key} = sub { $_[0]->{$key} };
}
BEGIN { __PACKAGE__->__accessor($_) for qw(type file ext dir) }

sub is_warning { 0 }
sub is_fatal   { 0 }
sub is_success { 0 }

package CPAN::Distroprefs::Result::Error;
use vars qw(@ISA);
BEGIN { @ISA = 'CPAN::Distroprefs::Result' } ## no critic
BEGIN { __PACKAGE__->__accessor($_) for qw(msg) }

sub as_string {
    my ($self) = @_;
    if ($self->msg) {
        return sprintf $self->fmt_reason, $self->file, $self->msg;
    } else {
        return sprintf $self->fmt_unknown, $self->file;
    }
}

package CPAN::Distroprefs::Result::Warning;
use vars qw(@ISA);
BEGIN { @ISA = 'CPAN::Distroprefs::Result::Error' } ## no critic
sub is_warning { 1 }
sub fmt_reason  { "Error reading distroprefs file %s, skipping: %s" }
sub fmt_unknown { "Unknown error reading distroprefs file %s, skipping." }

package CPAN::Distroprefs::Result::Fatal;
use vars qw(@ISA);
BEGIN { @ISA = 'CPAN::Distroprefs::Result::Error' } ## no critic
sub is_fatal { 1 }
sub fmt_reason  { "Error reading distroprefs file %s: %s" }
sub fmt_unknown { "Unknown error reading distroprefs file %s." }

package CPAN::Distroprefs::Result::Success;
use vars qw(@ISA);
BEGIN { @ISA = 'CPAN::Distroprefs::Result' } ## no critic
BEGIN { __PACKAGE__->__accessor($_) for qw(prefs extension) }
sub is_success { 1 }

package CPAN::Distroprefs::Iterator;

sub new { bless $_[1] => $_[0] }

sub next { $_[0]->() }

package CPAN::Distroprefs;

use Carp ();
use DirHandle;

sub _load_method {
    my ($self, $loader, $result) = @_;
    return '_load_yaml' if $loader eq 'CPAN' or $loader =~ /^YAML(::|$)/;
    return '_load_' . $result->ext;
}

sub _load_yaml {
    my ($self, $loader, $result) = @_;
    my $data = eval {
        $loader eq 'CPAN'
        ? $loader->_yaml_loadfile($result->abs)
        : [ $loader->can('LoadFile')->($result->abs) ]
    };
    if (my $err = $@) {
        die $result->as_warning({
            msg  => $err,
        });
    } elsif (!$data) {
        die $result->as_warning;
    } else {
        return @$data;
    }
}

sub _load_dd {
    my ($self, $loader, $result) = @_;
    my @data;
    {
        package CPAN::Eval;
        # this caused a die in CPAN.pm, and I am leaving it 'fatal', though I'm
        # not sure why we wouldn't just skip the file as we do for all other
        # errors. -- hdp
        my $abs = $result->abs;
        open FH, "<$abs" or die $result->as_fatal(msg => "$!");
        local $/;
        my $eval = <FH>;
        close FH;
        no strict;
        eval $eval;
        if (my $err = $@) {
            die $result->as_warning({ msg => $err });
        }
        my $i = 1;
        while (${"VAR$i"}) {
            push @data, ${"VAR$i"};
            $i++;
        }
    }
    return @data;
}

sub _load_st {
    my ($self, $loader, $result) = @_;
    # eval because Storable is never forward compatible
    my @data = eval { @{scalar $loader->can('retrieve')->($result->abs) } };
    if (my $err = $@) {
        die $result->as_warning({ msg => $err });
    }
    return @data;
}

sub find {
    my ($self, $dir, $ext_map) = @_;

    my $dh = DirHandle->new($dir) or Carp::croak("Couldn't open '$dir': $!");
    my @files = sort $dh->read;

    # label the block so that we can use redo in the middle
    return CPAN::Distroprefs::Iterator->new(sub { LOOP: {
        return unless %$ext_map;

        local $_ = shift @files;
        return unless defined;
        redo if $_ eq '.' || $_ eq '..';

        my $possible_ext = join "|", map { quotemeta } keys %$ext_map;
        my ($ext) = /\.($possible_ext)$/ or redo;
        my $loader = $ext_map->{$ext};

        my $result = CPAN::Distroprefs::Result->new({
            file => $_, ext => $ext, dir => $dir
        });
        # copied from CPAN.pm; is this ever actually possible?
        redo unless -f $result->abs; 

        my $load_method = $self->_load_method($loader, $result);
        my @prefs = eval { $self->$load_method($loader, $result) };
        if (my $err = $@) {
            if (ref($err) && eval { $err->isa('CPAN::Distroprefs::Result') }) {
                return $err;
            }
            # rethrow any exceptions that we did not generate
            die $err;
        } elsif (!@prefs) {
            # the loader should have handled this, but just in case:
            return $result->as_warning;
        }
        return $result->as_success({
            prefs => [
                map { CPAN::Distroprefs::Pref->new({ data => $_ }) } @prefs
            ],
        });
    } });
}

package CPAN::Distroprefs::Pref;

use Carp ();

sub new { bless $_[1] => $_[0] }

sub data { shift->{data} }

sub has_any_match { $_[0]->data->{match} ? 1 : 0 }

sub has_match { exists $_[0]->data->{match}{$_[1]} }

sub has_valid_subkeys {
    grep { exists $_[0]->data->{match}{$_} }
        $_[0]->match_attributes
}

sub _pattern {
    my ($self, $key) = @_;
    return eval sprintf 'qr{%s}', $self->data->{match}{$key};
}

sub _match {
    my ($self, $qr, $val) = @_;
    my $not = ($qr =~ s/!\s*//);
    $qr = eval sprintf 'qr{%s}', $qr;
    my $match = ($val =~ /$qr/);
    $match = !$match if $not;
    return $match;
}

sub _scalar_match {
    my ($self, $key, $data) = @_;
    return $self->_match($self->data->{match}{$key}, $data);
}

sub _hash_match {
    my ($self, $key, $data) = @_;
    my $match = $self->data->{match}{$key};
    for my $mkey (keys %$match) {
        my $val = defined $data->{$mkey} ? $data->{$mkey} : '';
        return 0 unless $self->_match($match->{$mkey}, $val);
    }
    return 1;
}

# do not take the order of C<keys %$match> because "module" is by far the
# slowest
sub match_attributes { qw(env distribution perl perlconfig module) }

sub match_module {
    my ($self, $modules) = @_;
    my $qr = $self->_pattern('module');
    for my $module (@$modules) {
        return 1 if $module =~ /$qr/;   
    }
    return 0;
}

sub match_distribution { shift->_scalar_match(distribution => @_) }
sub match_perl         { shift->_scalar_match(perl         => @_) }

sub match_perlconfig   { shift->_hash_match(perlconfig => @_) }
sub match_env          { shift->_hash_match(env        => @_) }

sub matches {
    my ($self, $arg) = @_;

    my $default_match = 0;
    for my $key (grep { $self->has_match($_) } $self->match_attributes) {
        unless (exists $arg->{$key}) {
            Carp::croak "Can't match pref: missing argument key $key";
        }
        $default_match = 1;
        my $val = $arg->{$key};
        # make it possible to avoid computing things until we have to
        if (ref($val) eq 'CODE') { $val = $val->() }
        my $meth = "match_$key";
        return 0 unless $self->$meth($val);
    }

    return $default_match;
}

1;

__END__

=head1 NAME

CPAN::Distroprefs -- read and match distroprefs

=head1 SYNOPSIS 

    use CPAN::Distroprefs;

    my %info = (... distribution/environment info ...);

    my $finder = CPAN::Distroprefs->find($prefs_dir, \%ext_map);

    while (my $result = $finder->next) {

        die $result->as_string if $result->is_fatal;

        warn $result->as_string, next if $result->is_warning;

        for my $pref (@{ $result->prefs }) {
            if ($pref->matches(\%info)) {
                return $pref;
            }
        }
    }


=head1 DESCRIPTION

This module encapsulates reading L<Distroprefs|CPAN> and matching them against CPAN distributions.

=head1 INTERFACE

    my $finder = CPAN::Distroprefs->find($dir, \%ext_map);

    while (my $result = $finder->next) { ... }

Build an iterator which finds distroprefs files in the given directory.

C<%ext_map> is a hashref whose keys are file extensions and whose values are
modules used to load matching files:

    {
        'yml' => 'YAML::Syck',
        'dd'  => 'Data::Dumper',
        ...
    }

Each time C<< $finder->next >> is called, the iterator returns one of two
possible values:

=over

=item * a CPAN::Distroprefs::Result object

=item * C<undef>, indicating that no prefs files remain to be found

=back

=head1 RESULTS

L<C<find()>|/INTERFACE> returns CPAN::Distroprefs::Result objects to
indicate success or failure when reading a prefs file.

=head2 Common

All results share some common attributes:

=head3 type

C<success>, C<warning>, or C<fatal>

=head3 file 

the file from which these prefs were read, or to which this error refers (relative filename)

=head3 ext

the file's extension, which determines how to load it

=head3 dir

the directory the file was read from

=head3 abs

the absolute path to the file

=head2 Errors

Error results (warning and fatal) contain:

=head3 msg

the error message (usually either C<$!> or a YAML error)

=head2 Successes

Success results contain:

=head3 prefs

an arrayref of CPAN::Distroprefs::Pref objects

=head1 PREFS 

CPAN::Distroprefs::Pref objects represent individual distroprefs documents.
They are constructed automatically as part of C<success> results from C<find()>.

=head3 data

the pref information as a hashref, suitable for e.g. passing to Kwalify

=head3 match_attributes

returns a list of the valid match attributes (see the Distroprefs section in L<CPAN>)

currently: C<env perl perlconfig distribution module>

=head3 has_any_match

true if this pref has a 'match' attribute at all

=head3 has_valid_subkeys

true if this pref has a 'match' attribute and at least one valid match attribute

=head3 matches

  if ($pref->matches(\%arg)) { ... }

true if this pref matches the passed-in hashref, which must have a value for
each of the C<match_attributes> (above)

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
