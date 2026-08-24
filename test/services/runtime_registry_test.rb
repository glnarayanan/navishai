require "test_helper"

class RuntimeRegistryTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    RuntimeInstallation.where(workspace: @workspace).delete_all
    @owner = memberships(:owner_support)
    @client = Object.new
    @reports = [ runtime_report ]
    reports = @reports
    runner_key = @workspace.runner_key
    @client.define_singleton_method(:detect_runtimes!) do |workspace_key:|
      raise "wrong workspace" unless workspace_key == runner_key

      reports
    end
  end

  test "detects, approves, bounds, and revokes an installation with attribution" do
    assert_difference [ "RuntimeInstallation.count", "AuditEvent.count" ], 1 do
      RuntimeRegistry.refresh!(workspace: @workspace, membership: @owner, client: @client)
    end
    installation = @workspace.runtime_installations.sole
    assert_equal "/opt/navishai/fixture", installation.executable_path
    assert_equal({ "authentication" => "managed_on_runner", "account_label" => "Fixture Team" }, installation.account_metadata)
    assert_not installation.runnable?

    assert_difference "AuditEvent.count", 1 do
      RuntimeRegistry.update_approval!(
        workspace: @workspace, membership: @owner, installation: installation,
        attributes: {
          approved: "1", allowed_role_keys: %w[support_investigator resolution_drafter],
          allowed_tools: %w[knowledge_search case_read],
          allowed_data_classes: %w[approved_knowledge case_content],
          profile_keys: %w[workspace_default fast],
          max_timeout_seconds: "420", max_steps: "12", max_tool_calls: "24",
          max_input_units: "120000", max_output_units: "30000"
        }
      )
    end
    installation.reload
    assert installation.runnable?
    assert_equal %w[resolution_drafter support_investigator], installation.allowed_role_keys
    assert_equal @owner, installation.approved_by_membership
    assert AuditEvent.where(action: "runtime.installation_approved", actor: @owner.user, subject_id: installation.id).exists?

    @reports[0] = runtime_report.merge("executable_version" => "fixture 2.5.0")
    RuntimeRegistry.refresh!(workspace: @workspace, membership: @owner, client: @client)
    assert_not installation.reload.approved?
    assert_equal "fixture 2.5.0", installation.executable_version
  end

  test "missing, unhealthy, incompatible, unauthorized, and cross-workspace installations fail closed" do
    RuntimeRegistry.refresh!(workspace: @workspace, membership: @owner, client: @client)
    installation = @workspace.runtime_installations.sole
    manager_user = User.create!(email_address: "runtime-manager@example.com", password: "password12345", verified_at: Time.current)
    manager = @workspace.memberships.create!(user: manager_user, role: :manager)
    assert_raises(Current::RoleAccessDenied) do
      RuntimeRegistry.refresh!(workspace: @workspace, membership: manager, client: @client)
    end
    foreign_user = User.create!(email_address: "foreign-runtime-admin@example.com", password: "password12345", verified_at: Time.current)
    foreign_admin = workspaces(:beta_support).memberships.create!(user: foreign_user, role: :admin)
    assert_raises(ActiveRecord::RecordNotFound) do
      RuntimeRegistry.update_approval!(
        workspace: workspaces(:beta_support), membership: foreign_admin, installation: installation,
        attributes: { approved: "0" }
      )
    end

    installation.update!(compatibility_status: "incompatible", incompatibility_reason: "Blocked version")
    assert_raises(RuntimeRegistry::InvalidPolicy) do
      RuntimeRegistry.update_approval!(
        workspace: @workspace, membership: @owner, installation: installation,
        attributes: approval_attributes
      )
    end
    assert_not installation.reload.approved?

    @reports.clear
    RuntimeRegistry.refresh!(workspace: @workspace, membership: @owner, client: @client)
    assert_equal "missing", installation.reload.health_status
    assert_not installation.runnable?
  end

  test "model and database reject secret metadata and incomplete approval attribution" do
    installation = @workspace.runtime_installations.build(runtime_report.slice(
      "detection_key", "adapter_key", "protocol_version", "executable_path", "executable_version",
      "account_metadata", "capabilities", "minimum_version", "maximum_version", "compatibility_status",
      "incompatibility_reason", "health_status", "checked_at"
    ).transform_keys(&:to_sym))
    installation.account_metadata = { "access_token" => "must-not-store" }
    assert_not installation.valid?
    assert_includes installation.errors[:account_metadata], "contains a secret-like field"

    assert_raises(ActiveRecord::StatementInvalid) do
      RuntimeInstallation.insert_all!([ installation.attributes.merge(
        account_metadata: {}, approved: true, approved_at: nil,
        created_at: Time.current, updated_at: Time.current
      ) ])
    end
  end

  private
    def runtime_report
      {
        "detection_key" => "a" * 64, "adapter_key" => "fixture", "protocol_version" => "v1",
        "executable_path" => "/opt/navishai/fixture", "executable_version" => "fixture 2.4.1",
        "account_metadata" => { "authentication" => "managed_on_runner", "account_label" => "Fixture Team" },
        "capabilities" => %w[structured_output tool_calling], "minimum_version" => "2.0.0",
        "maximum_version" => "2.x", "compatibility_status" => "compatible", "incompatibility_reason" => "",
        "health_status" => "available", "checked_at" => "2026-08-24T12:00:00Z"
      }
    end

    def approval_attributes
      {
        approved: "1", allowed_role_keys: [ "support_investigator" ], allowed_tools: [ "case_read" ],
        allowed_data_classes: [ "case_content" ], profile_keys: [ "workspace_default" ],
        max_timeout_seconds: "300", max_steps: "10", max_tool_calls: "20",
        max_input_units: "100000", max_output_units: "25000"
      }
    end
end
