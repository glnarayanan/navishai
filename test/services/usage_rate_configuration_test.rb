require "test_helper"

class UsageRateConfigurationTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "publishes bounded immutable versions and audits the active pointer" do
    published_at = Time.zone.parse("2026-08-27 12:00:00")

    assert_difference [ "UsageRateVersion.count", "AuditEvent.count" ], 1 do
      @version = publish(
        currency: "usd", source_name: "  2026 vendor rate card  ",
        input_rate: "2.50", output_rate: "8.125001", search_rate: "0.75",
        published_at:
      )
    end

    assert_equal "USD", @version.currency
    assert_equal "2026 vendor rate card", @version.source_name
    assert_equal 2_500_000, @version.input_rate_micros_per_million
    assert_equal 8_125_001, @version.output_rate_micros_per_million
    assert_equal 750_000, @version.search_rate_micros_per_million
    assert_equal published_at, @version.published_at
    assert_equal @version, @workspace.reload.usage_rate_setting.current_version
    assert_raises(ActiveRecord::ReadOnlyRecord) { @version.update!(currency: "EUR") }
    assert_raises(ActiveRecord::StatementInvalid) do
      UsageRateVersion.transaction(requires_new: true) do
        UsageRateVersion.where(id: @version.id).update_all(source_name: "Changed")
      end
    end

    audit = @workspace.audit_events.order(:id).last
    assert_equal "usage_rate.published", audit.action
    assert_equal @owner.user, audit.actor
    assert_equal({ "from_version" => 0, "to_version" => 1 }, audit.metadata)
  end

  test "rollback changes only the pointer and rejects stale or foreign choices" do
    first = publish(input_rate: "1", expected_current_version_id: nil)
    second = publish(input_rate: "2", expected_current_version_id: first.id)

    selected = UsageRateConfiguration.rollback!(
      workspace: @workspace, membership: @owner, version: first,
      expected_current_version_id: second.id
    )

    assert_equal first, selected
    assert_equal first, @workspace.reload.usage_rate_setting.current_version
    assert_equal [ 2, 1 ], @workspace.usage_rate_setting.versions.pluck(:version_number)
    assert_equal "usage_rate.rolled_back", @workspace.audit_events.order(:id).last.action
    assert_equal({ "from_version" => 2, "to_version" => 1 }, @workspace.audit_events.order(:id).last.metadata)

    error = assert_raises(UsageRateConfiguration::InvalidConfiguration) do
      publish(input_rate: "3", expected_current_version_id: second.id)
    end
    assert_includes error.message, "Rates changed"

    foreign_workspace = workspaces(:beta_support)
    foreign_admin = foreign_workspace.memberships.create!(user: users(:teammate), role: :admin)
    foreign = UsageRateConfiguration.publish!(
      workspace: foreign_workspace, membership: foreign_admin,
      attributes: base_attributes.merge(expected_current_version_id: nil)
    )
    assert_raises(ActiveRecord::RecordNotFound) do
      UsageRateConfiguration.rollback!(
        workspace: @workspace, membership: @owner, version: foreign,
        expected_current_version_id: first.id
      )
    end
  end

  test "only an Admin role can configure non-secret bounded rates" do
    member = @workspace.memberships.create!(user: users(:teammate), role: :member)
    assert_raises(Current::RoleAccessDenied) do
      UsageRateConfiguration.publish!(
        workspace: @workspace, membership: member,
        attributes: base_attributes.merge(expected_current_version_id: nil)
      )
    end

    [
      base_attributes.merge(currency: "US"),
      base_attributes.merge(source_name: ""),
      base_attributes.merge(input_rate: "1000000.000001"),
      base_attributes.merge(input_rate: "0.0000001"),
      base_attributes.merge(input_rate: "", output_rate: "", search_rate: "")
    ].each do |attributes|
      assert_raises(UsageRateConfiguration::InvalidConfiguration) do
        UsageRateConfiguration.publish!(
          workspace: @workspace, membership: @owner,
          attributes: attributes.merge(expected_current_version_id: nil)
        )
      end
    end
    assert_nil @workspace.reload.usage_rate_setting
  end

  private
    def publish(published_at: Time.current, **attributes)
      UsageRateConfiguration.publish!(
        workspace: @workspace, membership: @owner,
        attributes: base_attributes.merge(attributes), published_at:
      )
    end

    def base_attributes
      {
        expected_current_version_id: nil,
        currency: "USD", source_name: "Admin-entered public rate card",
        input_rate: "1", output_rate: "2", search_rate: "3"
      }
    end
end
