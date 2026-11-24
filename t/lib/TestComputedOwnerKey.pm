package TestComputedOwnerKey;
use 5.034;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(contract setup);

sub contract {
    return {schema_version => 1, name => 'Orders',
        source => {source_table => 'orders', primary_key => 'id',
            fields => [qw(id state_code hold_code origin_party_id destination_party_id inventory_location_id)],
            columns => {id => {type => 'integer'}, state_code => {type => 'string'}, hold_code => {type => 'string'},
                origin_party_id => {type => 'integer'}, destination_party_id => {type => 'integer'},
                inventory_location_id => {type => 'integer', computed => {kind => 'expression', expression => [
                    'case',
                    [['and', ['eq', 'hold_code', 'H'], ['eq', 'state_code', 'DL']], ['field', 'destination_party_id']],
                    [['and', ['eq', 'hold_code', 'H'], ['not', ['in', 'state_code', ['PL', 'DL', 'CX']]]], ['field', 'origin_party_id']],
                ]}}},
            associations => {inventory_location => {queryable => 'parties',
                owner_key => 'inventory_location_id', related_key => 'id'}}},
        schemas => {parties => {source_table => 'parties', primary_key => 'id',
            fields => [qw(id party_name city region)],
            columns => {id => {type => 'integer'}, map { $_ => {type => 'string'} } qw(party_name city region)},
            associations => {}}},
        joins => {inventory_location => {type => 'star_dimension', name => 'Inventory Location',
            display_field => 'party_name', dimension_key => 'inventory_location_id'}}};
}
sub setup {
    my ($dbh) = @_;
    $dbh->do($_) for
        'CREATE TEMPORARY TABLE orders (id integer primary key, state_code varchar(2), hold_code varchar(1), origin_party_id integer, destination_party_id integer)',
        'CREATE TEMPORARY TABLE parties (id integer primary key, party_name varchar(50), city varchar(50), region varchar(2))',
        'CREATE TEMPORARY TABLE party_flags (party_id integer, flag_id integer, info varchar(1))',
        q{INSERT INTO parties VALUES (1,'Alpha','Arc','CO'), (2,'Beta','Bay','UT'), (3,'Alpha','Cove','AZ')},
        q{INSERT INTO party_flags VALUES (1,22,'Y'), (2,22,'Y'), (3,22,'N')},
        q{INSERT INTO orders VALUES (1,'DL','H',1,2), (2,'OP','H',1,2), (3,'TR','H',2,1),
            (4,'PL','H',1,2), (5,'CX','H',1,2), (6,'DL','',1,2), (7,'OP',NULL,1,2),
            (8,NULL,'H',1,2), (9,'DL','H',1,NULL), (10,'OP','H',NULL,2), (11,'OP','H',3,1)};
}
1;
