require "test_helper"

class ResolutionContractConfigurationTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @families = ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    @support = @families.find { |family| family.family_key == "support_resolution" }
  end

  test "installs exactly one published low-risk version for each system family" do
    assert_equal ResolutionContractFamily::FAMILIES.keys.sort, @families.map(&:family_key).sort
    assert @families.all? { |family| family.versions.one? && family.current_version == family.versions.sole }
    assert @families.all? { |family| family.current_version.version_number == 1 }
    assert @families.all?(&:current_version)
    assert @families.all? { |family| family.current_version.missing_items_block? }
    assert @families.all? do |family|
      family.current_version.evidence_freshness_days == ResolutionContractConfiguration::DEFAULT_FRESHNESS_DAYS
    end

    assert_no_difference [ "ResolutionContractFamily.count", "ResolutionContractVersion.count" ] do
      ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    end
  end

  test "direct publication cannot bypass governed preview or change the current version" do
    current = @support.current_version

    assert_no_difference [ "ResolutionContractVersion.count", "AuditEvent.count" ] do
      error = assert_raises(ResolutionContractConfiguration::InvalidConfiguration) do
        ResolutionContractConfiguration.publish!(
          workspace: @workspace, membership: @owner, family: @support,
          attributes: attributes_for(current).merge(execution_budget_units: 75_000)
        )
      end
      assert_match(/proposal.*preview.*explicit canary/i, error.message)
    end
    assert_equal current, @support.reload.current_version
  end

  test "roles and another Workspace still fail closed before direct publication" do
    member_user = User.create!(email_address: "contract-member@example.com", password: "password12345", verified_at: Time.current)
    member = @workspace.memberships.create!(user: member_user, role: :member)

    assert_raises(Current::RoleAccessDenied) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: member, family: @support,
        attributes: attributes_for(@support.current_version)
      )
    end
    foreign = ResolutionContractConfiguration.install_defaults!(workspace: workspaces(:beta_support)).first
    assert_raises(ActiveRecord::RecordNotFound) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: foreign,
        attributes: attributes_for(foreign.current_version)
      )
    end
  end

  test "published versions remain immutable at model and database seams" do
    current = @support.current_version
    assert_raises(ActiveRecord::ReadOnlyRecord) { current.update!(execution_budget_units: 1) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ResolutionContractVersion.transaction(requires_new: true) do
        ResolutionContractVersion.where(id: current.id).delete_all
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ResolutionContractVersion.transaction(requires_new: true) do
        ResolutionContractVersion.insert_all!([ {
          workspace_id: @workspace.id, resolution_contract_family_id: @support.id, version_number: 3,
          required_claim_categories: [ "arbitrary_rule" ],
          evidence_freshness_days: ResolutionContractConfiguration::DEFAULT_FRESHNESS_DAYS,
          mandatory_review_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort,
          execution_budget_units: 100_000, missing_items_block: true,
          created_at: Time.current, updated_at: Time.current
        } ])
      end
    end
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
