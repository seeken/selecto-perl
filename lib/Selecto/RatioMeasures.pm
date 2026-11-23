package Selecto::RatioMeasures;
use 5.034;
use strict;
use warnings;
use Storable qw(dclone);
use Selecto::Error;
use Selecto::Expression;
use Selecto::Analytics::UnitRegistry;

sub definitions {
 my ($class,$domain)=@_;
 my $raw=($domain->_contract_view // {})->{ratio_measures} // {};
 Selecto::ConfiguredDomain->admit_library($raw);
 Selecto::Domain::_object($raw,'ratio_measures');
 my %result;
 for my $id(sort keys %$raw) {
  Selecto::Domain::_identifier($id,'ratio measure ID');
  my $r=$raw->{$id};
  Selecto::Domain::_object($r,"ratio measure $id");
  Selecto::Domain::_reject_unknown($r,{map {$_=>1} qw(label numerator denominator unit)},"ratio measure $id");
  Selecto::Domain::_nonblank_string($r->{label},"ratio measure $id label");
  my %units;
  for my $side(qw(numerator denominator)) {
   my $part=$r->{$side};
   Selecto::Domain::_object($part,"ratio measure $id $side");
   Selecto::Domain::_reject_unknown($part,{field=>1,function=>1},"ratio measure $id $side");
   my $field=Selecto::Domain::_nonblank_string($part->{field},'ratio field');
   my $resolved=eval {$domain->resolve($field)};
   Selecto::Error->throw('invalid_domain','ratio measures require numeric sum operands',{measure=>$id})
    unless $resolved && Selecto::Analytics::UnitRegistry->numeric_type($resolved->{type})
     && defined($part->{function}) && !ref($part->{function}) && $part->{function} eq 'sum';
   Selecto::Error->throw('invalid_domain','ratio measure operands must be public aggregatable fields',{measure=>$id})
    unless $domain->field_is_public($field) && ($domain->field_metadata($field)->{aggregatable} // 1);
   Selecto::Error->throw('invalid_domain','ratio operands cannot fan out owner rows',{measure=>$id})
    if grep {$_->cardinality eq 'many'} @{$resolved->{associations} // []};
   $units{$side}=Selecto::Analytics::UnitRegistry->column_unit($domain->field_metadata($field));
  }
  my $unit=exists($r->{unit}) ? Selecto::Analytics::UnitRegistry->normalize_unit($r->{unit})
   : {kind=>'ratio',numerator=>$units{numerator},denominator=>$units{denominator}};
  $result{$id}={%{dclone($r)},unit=>$unit};
 }
 return \%result;
}
sub expression {
 my ($class,$definition)=@_;
 return Selecto::Expression->ratio_of_sums($definition->{numerator}{field},$definition->{denominator}{field});
}
1;
