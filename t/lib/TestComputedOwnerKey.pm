package TestComputedOwnerKey;
use 5.034;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(contract setup);

sub contract {
    return {schema_version => 1, name => 'Synthetic loads',
        source => {source_table => 'ck_load', primary_key => 'id',
            fields => [qw(id status status2 orig_id dest_id inventory_location_id)],
            columns => {id => {type => 'integer'}, status => {type => 'string'}, status2 => {type => 'string'},
                orig_id => {type => 'integer'}, dest_id => {type => 'integer'},
                inventory_location_id => {type => 'integer', computed => {kind => 'expression', expression => [
                    'case',
                    [['and', ['eq', 'status2', 'I'], ['eq', 'status', 'D']], ['field', 'dest_id']],
                    [['and', ['eq', 'status2', 'I'], ['not', ['in', 'status', ['G', 'D', 'C']]]], ['field', 'orig_id']],
                ]}}},
            associations => {inventory_location => {queryable => 'client_party',
                owner_key => 'inventory_location_id', related_key => 'id'}}},
        schemas => {client_party => {source_table => 'ck_client_profile', primary_key => 'id',
            fields => [qw(id co_name city state)],
            columns => {id => {type => 'integer'}, map { $_ => {type => 'string'} } qw(co_name city state)},
            associations => {}}},
        joins => {inventory_location => {type => 'star_dimension', name => 'Inventory Location',
            display_field => 'co_name', dimension_key => 'inventory_location_id'}}};
}
sub setup {
    my ($dbh) = @_;
    $dbh->do($_) for
        'CREATE TEMPORARY TABLE ck_load (id integer primary key, status varchar(1), status2 varchar(1), orig_id integer, dest_id integer)',
        'CREATE TEMPORARY TABLE ck_client_profile (id integer primary key, co_name varchar(50), city varchar(50), state varchar(2))',
        'CREATE TEMPORARY TABLE ck_client_flags (client_id integer, flag_id integer, info varchar(1))',
        q{INSERT INTO ck_client_profile VALUES (1,'Alpha','Arc','CO'), (2,'Beta','Bay','UT'), (3,'Alpha','Cove','AZ')},
        q{INSERT INTO ck_client_flags VALUES (1,22,'Y'), (2,22,'Y'), (3,22,'N')},
        q{INSERT INTO ck_load VALUES (1,'D','I',1,2), (2,'P','I',1,2), (3,'R','I',2,1),
            (4,'G','I',1,2), (5,'C','I',1,2), (6,'D','N',1,2), (7,'P',NULL,1,2),
            (8,NULL,'I',1,2), (9,'D','I',1,NULL), (10,'P','I',NULL,2), (11,'P','I',3,1)};
}
1;
