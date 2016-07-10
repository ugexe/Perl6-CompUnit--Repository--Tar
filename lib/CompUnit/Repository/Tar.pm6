use Distribution::Common::Tar;
use nqp;

class CompUnit::Repository::Tar does CompUnit::Repository {
    has %!resources;#  %?RESOURCES has to return IO::Paths, so cache what we write to temp files
    has %!loaded;
    has $.prefix;

    my %seen;

    method !dist      { state $dist = Distribution::Common::Tar.new($.prefix.IO) }
    method !path2name { state %path2name = self!dist.meta<provides>.map({ (.value ~~ Str ?? .value !! .value.key) => .key }) }
    method !name2path { state %name2path = self!dist.meta<provides>.map({ .key => (.value ~~ Str ?? .value !! .value.key) }) }

    method need(CompUnit::DependencySpecification $spec,
                CompUnit::PrecompilationRepository $precomp = self.precomp-repository())
        returns CompUnit:D
    {
        my $name      = $spec.short-name;
        my $name-path = self!name2path{$name};

        if $name-path {
            my $base = $!prefix.IO.child($name-path);
            return %!loaded{$name} if %!loaded{$name}:exists;
            return %seen{$base}    if %seen{$base}:exists;

            my $id = nqp::sha1($name ~ $*REPO.id);
            my $*RESOURCES = Distribution::Resources.new(:repo(self), :dist-id(''));

            my $bytes  = Blob.new( self!dist.content($name-path).slurp-rest(:bin) );
            my $handle = CompUnit::Loader.load-source( $bytes );

            return %!loaded{$name} //= %seen{$base} = CompUnit.new(
                :short-name($name),
                :$handle,
                :repo(self),
                :repo-id($id),
                :!precompiled,
            );
        }

        return self.next-repo.need($spec, $precomp) if self.next-repo;
        X::CompUnit::UnsatisfiedDependency.new(:specification($spec)).throw;
    }

    method load(Str(Cool) $name-path) returns CompUnit:D {
        my $name = self!path2name{$name-path} // (self!name2path{$name-path} ?? $name-path !! Nil);
        my $path = self!name2path{$name-path} // (self!path2name{$name-path} ?? $name-path !! Nil);

        if $path {
            # XXX: Distribution::Common's .slurp-rest(:bin) doesn't work right yet, hence the `.encode`
            my $bytes  = Blob.new( self!dist.content($path).slurp-rest(:bin) );
            my $handle = CompUnit::Loader.load-source( $bytes );
            my $base   = ~$!prefix.IO.child($path);
            return %!loaded{$path} //= %seen{$base} = CompUnit.new(
                :$handle,
                :short-name($path),
                :repo(self),
                :repo-id(~$!prefix),
                :!precompiled,
            );
        }

        return self.next-repo.load($path) if self.next-repo;
        die("Could not find $path in:\n" ~ $*REPO.repo-chain.map(*.Str).join("\n").indent(4));
    }

    method loaded() returns Iterable {
        return %!loaded.values;
    }

    method id() {
        'tar'
    }

    method short-id() {
        'tar'
    }

    method path-spec() {
        'tar#'
    }

    method resource($dist-id, $key) {
        %!resources{$key} //= do {
            my $temp-repo-dir  = $*TMPDIR.child($*REPO.id);
            my $temp-dist-dir  = $temp-repo-dir.child(nqp::sha1(self!dist.Str));
            my $temp-file = $temp-dist-dir.child($key);

            mkdir $temp-repo-dir    unless $temp-repo-dir.e;
            mkdir $temp-dist-dir    unless $temp-dist-dir.e;
            mkdir $temp-file.parent unless $temp-file.parent.e;

            my $resource-handle = self!dist.content($key);
            my $resource-bytes  = Blob.new($resource-handle.open(:bin).slurp-rest(:bin));

            spurt $temp-file, $resource-bytes;
            IO::Path.new($temp-file);
        }
    }


    method files($file, :$name, :$auth, :$ver) {
        return () if ($name and self!dist.meta<meta><name> ne $name)
                  || ($auth and self!dist.meta<meta><auth> ne $auth)
                  || ($ver  and self!dist.meta<meta><ver>  ne $ver);

        my @libs  = self!path2name.keys;
        my @files = self!dist.meta<files>.map: { $_ ~~ Str ?? $_ !! $_.value }
        flat @libs, @files
    }
}