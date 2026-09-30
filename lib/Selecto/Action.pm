package Selecto::Action;

use 5.034;
use strict;
use warnings;
use Selecto::Action::Capability ();
use Selecto::Action::Planner ();

sub plan {
    my ($class, $domain, $intent) = @_;
    return Selecto::Action::Planner->plan($domain, $intent);
}

# Resolve conditional input specifications without requiring a write executor
# or a complete submission. Hosts use this for forms and lookup discovery;
# execution must still go through plan/authorize/execute.
sub input_form {
    my ($class, $action, $inputs) = @_;
    return Selecto::Action::Planner->input_form($action, $inputs);
}

sub authorize {
    my ($class, $plan, $phase, %options) = @_;
    return Selecto::Action::Capability->authorize($plan, $phase, %options);
}

sub capability_request {
    my ($class, $plan, $phase) = @_;
    return Selecto::Action::Capability->request($plan, $phase);
}

1;

__END__

=head1 NAME

Selecto::Action - plan and authorize declared domain actions

=head1 SYNOPSIS

  # In the domain contract:
  actions => {
      archive => {
          type       => 'transition',
          scope      => 'row',                        # or bulk
          capability => 'work_items.archive',
          transition => {field => 'state', from => 'done', to => 'archived'},
          inputs     => {reason => {type => 'string', required => 1}},
          execution  => {kind => 'updato', operation => 'update',
                         set  => {state => 'archived', archive_reason => ['input', 'reason']}},
      },
  },
  capabilities => {
      'work_items.archive' => {operations => ['action', 'update'], action => 'archive'},
  },

  # In the host:
  my $plan = Selecto::Action->plan($domain, {
      action => 'archive', target => 42, inputs => {reason => 'completed'},
  });
  my $decision = Selecto::Action->authorize($plan, 'preview',
      resolver => sub { my ($request, $context) = @_; return 'enabled' });

  # Or let the engine plan, authorize and execute in one governed path:
  my $done = $engine->execute_action($engine->plan_action($intent),
      resolver => $policy, context => {actor => {id => $user_id}});

=head1 DESCRIPTION

An action is a named state change the domain declares, such as "archive",
"approve" or "restock". Callers supply only the action name, a target and
declared inputs; the domain fixes the operation, the assignments, the
transition and any preconditions. The result of planning is a
L<Selecto::Action::Plan>: a constrained write intent with an exact expected
cardinality.

Authorization is a separate step. Every action with a C<capability> must be
approved by a host I<resolver> for each phase (C<preview> and C<execute>).
Missing resolvers and C<hidden> or C<disabled> decisions fail closed.

L<Selecto::Engine/ACTIONS> is the usual way to run a plan: it
authorizes, builds the write command from the plan and executes it through
the same governance and tenant scope as any other write.

=head1 CLASS METHODS

=head2 plan

  my $plan = Selecto::Action->plan($domain_or_contract, {
      action => 'archive',
      target => 42,                   # row scope: one primary key
      # target => {ids => [3, 4, 5]}, # bulk scope: exact ids
      inputs => {reason => 'completed'},
  });

Validates the intent against the declared action and returns a
L<Selecto::Action::Plan>. Row targets have cardinality exactly one; bulk
targets have cardinality equal to the number of ids and need C<bulk> on the
write operation (a row action accepts C<ids> only with
C<< bulk => {enabled => 1} >>). Transitions add a
source-state filter and must be allowed by C<writes.transitions>. Declared
C<preconditions> are added as filters (see F<docs/action-preconditions.md>).

Common errors: C<invalid_action_intent> (unknown action),
C<action_scope_mismatch> (wrong target shape), C<unknown_action_input>,
C<missing_action_input>, C<action_operation_not_enabled>,
C<unsupported_action_executor>.

=head2 authorize

  my $decision = Selecto::Action->authorize($plan, $phase,
      resolver => $resolver, context => \%context);
  # {status => 'enabled', capability => 'work_items.archive'}

Calls C<< $resolver->($request, $context, \%options) >>, where C<$request>
is L</capability_request>. The resolver returns C<enabled>, C<disabled>,
C<hidden>, or a hash C<< {status => ..., reason => ..., code => ...} >>.
Anything but C<enabled> throws (C<action_capability_denied> by default, or
the decision's C<code>). An action without a capability is always enabled.
Without a resolver, C<missing_capability_resolver> is thrown with
C<< status => 'hidden' >> in its details.

=head2 capability_request

  my $request = Selecto::Action->capability_request($plan, 'execute');

The data a resolver receives: C<phase>, C<capability>, C<action>,
C<operation>, C<scope>, C<target>, C<filters>, C<transition> and
C<preconditions>.

=head2 input_form

  my $form = Selecto::Action->input_form($domain->actions->{check_in}, {
      documents_complete => 'false',
  });
  # {variant => 'missing_documents', inputs => {...effective specs...}, execution => {...}}

Resolves which variant a partial submission selects and returns the
effective input specifications, for building forms. It does not authorize
or execute anything; C<plan> still validates the complete submission.

=head1 DECLARING ACTIONS

=over 4

=item C<type>, C<scope>

C<scope> is C<row> or C<bulk>. C<type> is descriptive (for example
C<transition>, C<row_action>, C<bulk_action>).

=item C<execution>

C<< {kind => 'updato', operation => 'update', set => {...}} >>. C<kind> must
be C<updato>, the portable executor. C<operation> is C<insert>, C<update>,
C<upsert> or C<delete> and must be enabled in C<writes.operations>. C<set>
values may be literals, C<['input', 'name']> references, or
C<['system', 'now']> for the current timestamp. Upserts may name a
C<conflict_target> declared under C<writes.operations.upsert.conflict_targets>.
C<cases> selects one of several executions by input values.

=item C<inputs>

A map (or list with C<id>s) of input specifications with C<type>
(C<boolean> and C<collection> are normalized), C<required>, C<default> and
labels for user interfaces.

=item C<variants>

A list of C<< {id => ..., when => {input => value}, inputs => {...},
execution => {...}} >>; exactly one must match the normalized base inputs.

=item C<transition>

C<< {field => 'state', from => 'done', to => 'archived'} >>.

=item C<preconditions>

Extra guards such as C<[['eligible', 1], ['<=', 'priority', 3]]>; update and
delete only.

=item C<selection>

For C<ids> targets: C<< {mode => 'rows', min_rows => 1, max_rows => 50,
presentation => 'toolbar'} >>. The planner enforces the row bounds
(C<action_cardinality_mismatch>);
C<presentation> (C<toolbar>, C<row_dialog>, C<row_inline>) is a hint for user
interfaces, and row presentations require C<< max_rows => 1 >>.

=item C<capability>

The key of an entry in C<capabilities> whose C<operations> include
C<action> and the action's operation.

=back

=head1 SEE ALSO

L<Selecto>, L<Selecto::Engine/ACTIONS>, L<Selecto::Action::Plan>,
L<Selecto::Action::Grant>, F<docs/action-preconditions.md>

=head1 AUTHOR

Chris Rohlfs <seeken@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2026 by Chris Rohlfs.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
