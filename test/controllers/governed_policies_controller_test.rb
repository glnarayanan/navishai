require "test_helper"

class GovernedPoliciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @family = ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
      .find_by!(family_key: "support_resolution")
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
    @support_case = create_support_case
  end

  test "an Owner can inspect, preview, publish, and roll back one explicit policy" do
    proposal = propose
    sign_in_as @owner.user

    get workspace_governed_policy_path(@workspace)
    assert_response :success
    assert_select "h1", "Review policy changes"
    assert_select "[role='note']", text: /cannot predict response quality, customer behavior, resolution rate, or any causal outcome/
    assert_select "#proposal-#{proposal.id}", text: /Needs preview/

    post preview_workspace_governed_policy_path(@workspace, proposal_id: proposal.id)
    preview = proposal.previews.reload.sole
    assert_redirected_to workspace_governed_policy_path(@workspace, anchor: "preview-#{preview.id}")

    post publish_workspace_governed_policy_path(@workspace, proposal_id: proposal.id), params: { preview_id: preview.id }
    publication = preview.reload.publication
    assert_redirected_to workspace_governed_policy_path(@workspace, anchor: "publication-#{publication.id}")

    post rollback_workspace_governed_policy_path(@workspace, publication_id: publication.id), params: {
      expected_publication_id: publication.id, reason: "Canary check complete"
    }
    rollback = publication.reload.successor
    assert_redirected_to workspace_governed_policy_path(@workspace, anchor: "publication-#{rollback.id}")
    assert_predicate rollback, :rollback_action?
  end

  test "Owner and Admin can access policy actions while lower roles cannot" do
    %i[owner admin].each do |role|
      user = create_user("policy-#{role}@example.com")
      @workspace.memberships.create!(user:, role:)
      sign_in_as user
      get workspace_governed_policy_path(@workspace)
      assert_response :success
    end

    %i[manager member viewer].each do |role|
      user = create_user("policy-#{role}@example.com")
      @workspace.memberships.create!(user:, role:)
      sign_in_as user
      get workspace_governed_policy_path(@workspace)
      assert_response :forbidden
    end
  end

  test "proposal forms expose the current isolation policy and allowed choices" do
    sign_in_as @owner.user

    get workspace_governed_policy_path(@workspace)

    assert_response :success
    select_id = "profile_#{@profile.id}_isolation_policy"
    assert_select "label[for='#{select_id}']", "Execution isolation"
    assert_select "select##{select_id}[name='governed_policy[profile][isolation_policy]']" do
      assert_select "option[value='strong_isolation_required'][selected]", "Strong isolation required"
      assert_select "option[value='host_trusted_allowed']", "Host-trusted execution allowed"
    end
  end

  test "an Owner can propose host-trusted isolation through the controller" do
    sign_in_as @owner.user
    contract = @family.current_version
    profile = @profile.current_version

    assert_difference "@workspace.governed_policy_proposals.count", 1 do
      post propose_workspace_governed_policy_path(@workspace), params: {
        governed_policy: {
          resolution_contract_family_id: @family.id,
          agent_profile_id: @profile.id,
          scope_kind: "support_case",
          support_case_ids: [ @support_case.id ],
          contract: {
            required_claim_categories: contract.required_claim_categories,
            evidence_freshness_days: contract.evidence_freshness_days,
            mandatory_review_checks: contract.mandatory_review_checks,
            execution_budget_units: contract.execution_budget_units,
            missing_items_block: contract.missing_items_block
          },
          profile: {
            runtime_profile_key: profile.runtime_profile_key,
            fallback_profile_keys: profile.fallback_profile_keys,
            timeout_seconds: profile.timeout_seconds,
            max_steps: profile.max_steps,
            max_tool_calls: profile.max_tool_calls,
            review_policy: profile.review_policy,
            isolation_policy: "host_trusted_allowed"
          },
          reason: "Allow an approved host-trusted runtime"
        }
      }
    end

    proposal = @workspace.governed_policy_proposals.order(:id).last
    assert_equal "host_trusted_allowed", proposal.agent_profile_version.isolation_policy
    assert_redirected_to workspace_governed_policy_path(@workspace, anchor: "proposal-#{proposal.id}")
  end

  test "same and foreign Organization Workspace policy records fail closed without disclosure" do
    proposal = propose
    [ [ workspaces(:acme_success), "same-org-policy-controller@example.com" ],
      [ workspaces(:beta_support), "foreign-policy-owner@example.com" ] ].each do |workspace, email|
      actor = workspace.memberships.create!(user: create_user(email), role: :owner)
      sign_in_as actor.user

      post preview_workspace_governed_policy_path(workspace, proposal_id: proposal.id)
      assert_response :not_found
      refute_includes response.body, proposal.reason
    end
  end

  private
    def propose
      contract = @family.current_version
      profile = @profile.current_version
      GovernedPolicyChange.propose!(
        workspace: @workspace, membership: @owner, family: @family, profile: @profile,
        scope_kind: "support_case", scope_ids: [ @support_case.id ],
        contract_attributes: {
          required_claim_categories: contract.required_claim_categories,
          evidence_freshness_days: contract.evidence_freshness_days,
          mandatory_review_checks: contract.mandatory_review_checks,
          execution_budget_units: contract.execution_budget_units,
          missing_items_block: contract.missing_items_block
        },
        profile_attributes: {
          runtime_profile_key: profile.runtime_profile_key,
          fallback_profile_keys: profile.fallback_profile_keys,
          timeout_seconds: profile.timeout_seconds,
          max_steps: profile.max_steps,
          max_tool_calls: profile.max_tool_calls,
          review_policy: profile.review_policy
        },
        reason: "Controller acceptance"
      )
    end

    def create_user(email)
      User.create!(email_address: email, password: "password12345", verified_at: Time.current)
    end
end
