require "test_helper"

class ResolutionContractsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @family = ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
      .find_by!(family_key: "support_resolution")
    @version = @family.current_version
  end

  test "an Owner must use the governed policy path" do
    sign_in_as users(:owner)

    assert_no_difference [ "ResolutionContractVersion.count", "AuditEvent.count" ] do
      patch workspace_resolution_contract_path(@workspace, @family), params: {
        resolution_contract: attributes_for(@version).merge(
          execution_budget_units: "80000",
          required_claim_categories: %w[customer_account_fact policy_entitlement]
        )
      }
    end

    assert_response :unprocessable_content
    assert_select ".inline-error", text: /immutable proposal.*preview.*explicit canary/i
    assert_equal @version, @family.reload.current_version
  end

  test "invalid input rerenders its open contract without losing values" do
    sign_in_as users(:owner)

    assert_no_difference [ "ResolutionContractVersion.count", "AuditEvent.count" ] do
      patch workspace_resolution_contract_path(@workspace, @family), params: {
        resolution_contract: attributes_for(@version).merge(
          execution_budget_units: "0",
          required_claim_categories: %w[customer_account_fact]
        )
      }
    end

    assert_response :unprocessable_content
    assert_select "#contract-#{@family.id}[open]"
    assert_select ".inline-error", text: /immutable proposal.*preview.*explicit canary/i
  end

  test "members and foreign contract paths fail closed" do
    member_user = User.create!(email_address: "contract-controller-member@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: member_user, role: :member)
    sign_in_as member_user

    patch workspace_resolution_contract_path(@workspace, @family), params: {
      resolution_contract: attributes_for(@version)
    }
    assert_response :forbidden

    sign_in_as users(:owner)
    foreign = ResolutionContractConfiguration.install_defaults!(workspace: workspaces(:beta_support)).first
    patch workspace_resolution_contract_path(@workspace, foreign), params: {
      resolution_contract: attributes_for(foreign.current_version)
    }
    assert_response :not_found
  end

  private
    def attributes_for(version)
      {
        expected_current_version_id: version.id,
        required_claim_categories: version.required_claim_categories,
        evidence_freshness_days: version.evidence_freshness_days,
        mandatory_review_checks: version.mandatory_review_checks,
        execution_budget_units: version.execution_budget_units,
        missing_items_block: version.missing_items_block
      }
    end
end
