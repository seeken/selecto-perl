use strict;
use warnings;
use Test::More;
use DBI;
use Selecto::SQLite;
use Selecto::QueryBudget;
{
    package ExternalBudgetAdapter;
    use Mojo::Base 'Selecto::SQLite';
    our @EVENTS;
    sub native_query_budget_supported { 1 }
    sub configure_query_budget {
        my ($self, $milliseconds, $budget) = @_;
        push @EVENTS, ['configured', $milliseconds];
        $budget->install_restore(sub { push @EVENTS, ['restored']; });
        $budget->install_rearm(sub { push @EVENTS, ['rearmed']; });
        return 1;
    }
}
my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError => 1, PrintError => 0});
my $adapter = ExternalBudgetAdapter->new(dbh => $dbh);
ok(Selecto::QueryBudget->supported($adapter), 'public native support strategy selected');
my $budget = Selecto::QueryBudget->begin($adapter, timeout_ms => 1000);
is_deeply($ExternalBudgetAdapter::EVENTS[0], ['configured', 1000], 'selected adapter receives exact budget');
$budget->check;
$budget->close;
is_deeply(\@ExternalBudgetAdapter::EVENTS, [['configured', 1000], ['rearmed'], ['restored']], 'public callbacks rearm and restore exactly once');
ok($dbh->{Active}, 'host still owns connected DBI handle');
$dbh->disconnect;
done_testing;
