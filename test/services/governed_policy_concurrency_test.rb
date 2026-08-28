require "test_helper"

class GovernedPolicyConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(5)
    organization = Organization.create!(name: "Policy race #{suffix}", slug: "policy-race-#{suffix}")
    @workspace = organization.workspaces.create!(name: "Policy race", slug: "policy-race")
    user = User.create!(
      email_address: "policy-race-#{suffix}@example.com", password: "password12345", verified_at: Time.current
    )
    @owner = @workspace.memberships.create!(user:, role: :owner)
    account = @workspace.accounts.create!(name: "Race account")
    contact = @workspace.contacts.create!(account:, name: "Race contact")
    @support_case = create_support_case(workspace: @workspace, contact:, membership: @owner)
    @family = @workspace.resolution_contract_families.find_by!(family_key: "support_resolution")
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    install_runtime
  end

  teardown do
    next unless @workspace && Workspace.exists?(@workspace.id)

    tables = WorkspaceDeletion.send(:workspace_tables)
    Workspace.transaction do
      WorkspaceDeletion.send(:delete_workspace_records!, @workspace, tables)
    end
  end

  test "duplicate publication and rollback races leave one durable successor each" do
    proposal = GovernedPolicyChange.propose!(
      workspace: @workspace, membership: @owner, family: @family, profile: @profile,
      scope_kind: "support_case", scope_ids: [ @support_case.id ],
      contract_attributes: contract_attributes.merge(execution_budget_units: 99_000),
      profile_attributes:, reason: "Concurrent canary"
    )
    preview = GovernedPolicyChange.preview!(workspace: @workspace, membership: @owner, proposal:)

    publications = race do
      GovernedPolicyChange.publish!(
        workspace: Workspace.find(@workspace.id), membership: Membership.find(@owner.id),
        proposal: GovernedPolicyProposal.find(proposal.id), preview: GovernedPolicyPreview.find(preview.id)
      )
    end
    assert_equal 1, publications.count { |result| result.is_a?(GovernedPolicyPublication) }
    assert_equal 1, publications.count { |result| result.is_a?(GovernedPolicyChange::StalePreview) }
    canary = @workspace.governed_policy_publications.canary_action.sole

    rollbacks = race do
      GovernedPolicyChange.rollback!(
        workspace: Workspace.find(@workspace.id), membership: Membership.find(@owner.id),
        publication: GovernedPolicyPublication.find(canary.id),
        expected_publication_id: canary.id, reason: "Concurrent rollback"
      )
    end
    assert_equal 1, rollbacks.count { |result| result.is_a?(GovernedPolicyPublication) }
    assert_equal 1, rollbacks.count { |result| result.is_a?(GovernedPolicyChange::StalePreview) }
    assert_equal 2, @workspace.governed_policy_publications.count
    assert_equal @workspace.governed_policy_publications.rollback_action.sole, canary.reload.successor
    assert_equal 3, @workspace.audit_events.where(action: %w[
      governed_policy.proposed governed_policy.canary_published governed_policy.rolled_back
    ]).count
  end

  private
    def race(&block)
      ready = Queue.new
      release = Queue.new
      results = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            results << block.call
          rescue StandardError => error
            results << error
          end
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      threads.each(&:join)
      2.times.map { results.pop }
    end

    def install_runtime
      source = runtime_installations(:acme_scripted)
      attributes = source.attributes.except(
        "id", "workspace_id", "created_at", "updated_at", "approved",
        "approved_by_membership_id", "approved_by_user_id", "approved_at"
      )
      @workspace.runtime_installations.create!(
        **attributes, approved: true, approved_by_membership: @owner,
        approved_by_user: @owner.user, approved_at: Time.current
      )
    end

    def contract_attributes
      version = @family.current_version
      {
        required_claim_categories: version.required_claim_categories,
        evidence_freshness_days: version.evidence_freshness_days,
        mandatory_review_checks: version.mandatory_review_checks,
        execution_budget_units: version.execution_budget_units,
        missing_items_block: version.missing_items_block
      }
    end

    def profile_attributes
      version = @profile.current_version
      {
        runtime_profile_key: version.runtime_profile_key,
        fallback_profile_keys: version.fallback_profile_keys,
        timeout_seconds: version.timeout_seconds,
        max_steps: version.max_steps,
        max_tool_calls: version.max_tool_calls,
        review_policy: version.review_policy
      }
    end
end
