class GovernedPolicyResolver
  Selection = Data.define(:publication, :resolution_contract_version, :agent_profile_version) do
    def canary?
      publication&.canary_action? || false
    end
  end

  def self.resolve(workspace:, scope:, profile:)
    new(workspace:).resolve(scope:, profile:)
  end

  def self.lock_workspace!(workspace)
    quoted = GovernedPolicyPublication.connection.quote("governed-policy:#{workspace.id}")
    GovernedPolicyPublication.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{quoted}))")
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def resolve(scope:, profile:)
    profile = @workspace.agent_profiles.includes(:current_version, :crew_template).find(profile.id)
    scope = scoped_record(scope)
    family_key = profile.crew_template.support? ? "support_resolution" : "customer_success_intervention"
    family = @workspace.resolution_contract_families.includes(:current_version).find_by(family_key:)
    unless family
      ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
      family = @workspace.resolution_contract_families.includes(:current_version).find_by!(family_key:)
    end
    publication = matching_publication(scope, profile, family)
    Selection.new(
      publication,
      publication&.resolution_contract_version || family.current_version,
      publication&.agent_profile_version || profile.current_version
    )
  end

  private
    def scoped_record(scope)
      case scope
      when SupportCase then @workspace.support_cases.find(scope.id)
      when Account then @workspace.accounts.find(scope.id)
      else raise ActiveRecord::RecordNotFound
      end
    end

    def matching_publication(scope, profile, family)
      account_id = scope.is_a?(Account) ? scope.id : scope.conversation.contact.account_id
      conditions = <<~SQL.squish
        (governed_policy_subjects.subject_kind = 'support_case' AND
          governed_policy_subjects.support_case_id = :support_case_id) OR
        (governed_policy_subjects.subject_kind = 'account' AND
          governed_policy_subjects.account_id = :account_id) OR
        (governed_policy_subjects.subject_kind = 'agent_profile' AND
          governed_policy_subjects.agent_profile_id = :agent_profile_id)
      SQL
      matches = @workspace.governed_policy_publications
        .joins(proposal: :subjects)
        .where(expired_at: nil)
        .where(governed_policy_proposals: {
          resolution_contract_family_id: family.id, agent_profile_id: profile.id
        })
        .where(conditions, support_case_id: scope.is_a?(SupportCase) ? scope.id : nil,
          account_id:, agent_profile_id: profile.id)
        .distinct
        .to_a
      matches.max_by do |publication|
        rank = { "support_case" => 3, "account" => 2, "agent_profile" => 1 }.fetch(publication.scope_kind)
        [ rank, publication.id ]
      end
    end
end
