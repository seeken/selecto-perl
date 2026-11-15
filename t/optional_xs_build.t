use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin qw($Bin);
use Cwd qw(getcwd);
use Config;
use IPC::Open3;
use Symbol qw(gensym);

my $root="$Bin/..";
my $tmp=tempdir(CLEANUP=>1);
make_path("$tmp/lib", "$tmp/xs");
copy("$root/Makefile.PL","$tmp/Makefile.PL") or die $!;
copy("$root/lib/Selecto.pm","$tmp/lib/Selecto.pm") or die $!;
copy("$root/xs/CanonicalXS.xs","$tmp/xs/CanonicalXS.xs") or die $!;
sub run {
    my (@args)=@_;
    my $err=gensym;
    my $pid=open3(undef,my $out,$err,@args);
    my $text=do {local $/;<$out>} // '';
    $text.=do {local $/;<$err>} // '';
    waitpid($pid,0);
    return ($?,$text);
}
# A previous native build may have left generated C behind.
open my $stale,'>',"$tmp/CanonicalXS.c" or die $!;
print {$stale} "#error disabled native code must not compile\n";close $stale;
my $cwd=getcwd();
chdir($tmp) or die $!;
my ($status,$text)=run($^X,'Makefile.PL',"CC=$tmp/absent-compiler");
is($status,0,'configuration succeeds without a compiler') or diag $text;
like($text,qr/pure Perl/,'configuration selects Perl fallback');
open my $mf,'<','Makefile' or die $!;
my $makefile=do {local $/;<$mf>};close $mf;
unlike($makefile,qr/^XS_FILES[ \t]*=[ \t]*\S/m,'disabled build has no native source target');
($status,$text)=run($Config{make},'-s');
is($status,0,'build succeeds without a compiler') or diag $text;
chdir($cwd) or die $!;
done_testing;
