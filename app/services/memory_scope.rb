class MemoryScope
  Context = Data.define(:workspace, :account, :contact, :support_case, :crew_template, :agent_profile, :user) do
    def initialize(workspace:, account: nil, contact: nil, support_case: nil, crew_template: nil, agent_profile: nil, user: nil)
      super
    end
  end

  def self.resolve(context:)
    new(context).resolve
  end

  def initialize(context)
    @context = context
  end

  def resolve
    validate_context!
    targets = inherited_targets
    base = MemoryRecord.where(workspace: context.workspace)
    clauses = [
      base.where(scope_kind: :organization, organization: context.workspace.organization),
      base.where(scope_kind: :workspace)
    ]
    clauses << base.where(scope_kind: :account, account: targets[:account]) if targets[:account]
    clauses << base.where(scope_kind: :contact, contact: targets[:contact]) if targets[:contact]
    clauses << base.where(scope_kind: :support_case, support_case: context.support_case) if context.support_case
    clauses << base.where(scope_kind: :crew, crew_template: targets[:crew_template]) if targets[:crew_template]
    clauses << base.where(scope_kind: :agent, agent_profile: context.agent_profile) if context.agent_profile
    clauses << base.where(scope_kind: :user, user: context.user) if context.user
    clauses.reduce { |relation, clause| relation.or(clause) }
  end

  private
    attr_reader :context

    def inherited_targets
      contact = context.contact || context.support_case&.conversation&.contact
      {
        contact: contact,
        account: context.account || contact&.account,
        crew_template: context.crew_template || context.agent_profile&.crew_template
      }
    end

    def validate_context!
      records = [ context.account, context.contact, context.support_case, context.crew_template, context.agent_profile ].compact
      if records.any? { |record| record.workspace_id != context.workspace.id }
        raise ArgumentError, "memory scope targets must belong to the workspace"
      end
      case_contact = context.support_case&.conversation&.contact
      if context.contact && case_contact && context.contact != case_contact
        raise ArgumentError, "memory case and contact scopes must match"
      end
      contact = context.contact || case_contact
      if context.account && contact&.account && context.account != contact.account
        raise ArgumentError, "memory contact and account scopes must match"
      end
      if context.crew_template && context.agent_profile && context.crew_template != context.agent_profile.crew_template
        raise ArgumentError, "memory agent and crew scopes must match"
      end
      if context.user && !Membership.exists?(workspace: context.workspace, user: context.user)
        raise ArgumentError, "memory user scope requires a workspace membership"
      end
    end
end
