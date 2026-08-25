require "test_helper"

class WorkspaceDataControlsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @policy = @workspace.create_workspace_data_policy!
  end

  test "owner sees and updates separate content and audit retention" do
    sign_in_as users(:owner)

    get workspace_data_controls_path(@workspace)

    assert_response :success
    assert_select "h1", "Data controls"
    assert_select "select[name='workspace_data_policy[content_retention_days]']"
    assert_select ".nav-label", text: "Data"

    assert_difference "AuditEvent.count", 1 do
      patch workspace_data_controls_path(@workspace), params: {
        workspace_data_policy: { content_retention_days: "365", audit_retention_days: "2555" }
      }
    end

    assert_redirected_to workspace_data_controls_path(@workspace)
    assert_equal 365, @policy.reload.content_retention_days
    assert_equal 2555, @policy.audit_retention_days
    audit = AuditEvent.order(:id).last
    assert_equal "workspace.data_policy_updated", audit.action
    assert_equal users(:owner), audit.actor
    assert_equal({ "content_retention_days" => 365, "audit_retention_days" => 2555 }, audit.metadata)
  end

  test "audit retention cannot be shorter than content retention" do
    sign_in_as users(:owner)

    assert_no_difference "AuditEvent.count" do
      patch workspace_data_controls_path(@workspace), params: {
        workspace_data_policy: { content_retention_days: "1825", audit_retention_days: "365" }
      }
    end

    assert_response :unprocessable_content
    assert_select ".inline-error", text: /Audit retention days must be at least as long/
    assert_nil @policy.reload.content_retention_days
  end

  test "non-owners cannot inspect or change the policy" do
    membership = @workspace.memberships.create!(user: users(:teammate), role: :manager)
    sign_in_as membership.user

    get workspace_data_controls_path(@workspace)
    assert_response :forbidden

    assert_no_difference "AuditEvent.count" do
      patch workspace_data_controls_path(@workspace), params: {
        workspace_data_policy: { content_retention_days: "30", audit_retention_days: "365" }
      }
    end
    assert_response :forbidden

    get workspace_support_cases_path(@workspace)
    assert_select ".nav-label", text: "Data", count: 0
  end

  test "owner can queue an irreversible content expiry run" do
    @policy.update!(content_retention_days: 30, audit_retention_days: 365)
    sign_in_as users(:owner)

    assert_enqueued_with job: WorkspaceContentExpiryJob do
      post expire_workspace_data_controls_path(@workspace)
    end

    assert_redirected_to workspace_data_controls_path(@workspace)
    run = @workspace.workspace_content_expiry_runs.last
    assert run.pending?
    assert_equal 30.days.ago.to_date, run.cutoff_at.to_date

    get workspace_data_controls_path(@workspace)
    assert_select "h2", "Content expiry"
    assert_select "form[action='#{expire_workspace_data_controls_path(@workspace)}']"
    assert_select "td", "Pending"
  end

  test "owner can queue separate audit expiry" do
    @policy.update!(audit_retention_days: 365)
    sign_in_as users(:owner)

    assert_enqueued_with job: WorkspaceAuditExpiryJob do
      post expire_audit_workspace_data_controls_path(@workspace)
    end

    assert_redirected_to workspace_data_controls_path(@workspace)
    assert_equal "pending", @policy.reload.audit_expiry_status
    assert_equal 365.days.ago.to_date, @policy.audit_expiry_cutoff_at.to_date

    get workspace_data_controls_path(@workspace)
    assert_select "h2", "Audit expiry"
    assert_select "form[action='#{expire_audit_workspace_data_controls_path(@workspace)}']"
    assert_select "dd", "Pending"
  end

  test "owner downloads a compressed complete workspace export" do
    sign_in_as users(:owner)

    assert_difference "AuditEvent.count", 1 do
      get export_workspace_data_controls_path(@workspace)
    end

    assert_response :success
    assert_equal "application/gzip", response.media_type
    assert_match(/navishai-workspace-support-.*\.tar\.gz/, response.headers.fetch("Content-Disposition"))
    gzip = Zlib::GzipReader.new(StringIO.new(response.body))
    archive = nil
    Gem::Package::TarReader.new(gzip) do |tar|
      archive = JSON.parse(tar.find { |entry| entry.full_name == "manifest.json" }.read)
    end
    assert_equal "navishai-workspace-v2", archive.fetch("format")
    assert_equal @workspace.runner_key, archive.dig("workspace", "runner_key")
  end

  test "owner imports an archive as a new workspace" do
    archive = WorkspacePortability.export(workspace: @workspace, membership: memberships(:owner_support))
    file = Tempfile.new([ "workspace", ".tar.gz" ], binmode: true)
    IO.copy_stream(archive, file)
    file.rewind
    sign_in_as users(:owner)

    assert_difference "Workspace.count", 1 do
      post import_workspace_data_controls_path(@workspace), params: {
        workspace_name: "Imported Support", workspace_slug: "imported-support",
        workspace_archive: Rack::Test::UploadedFile.new(file.path, "application/gzip")
      }
    end

    imported = @workspace.organization.workspaces.find_by!(slug: "imported-support")
    assert_redirected_to workspace_data_controls_path(imported)
    assert imported.memberships.find_by(user: users(:owner)).owner?
  ensure
    file&.close!
  end

  test "invalid import rerenders without creating a workspace" do
    file = Tempfile.new([ "workspace", ".json.gz" ], binmode: true)
    file.write("not gzip")
    file.rewind
    sign_in_as users(:owner)

    assert_no_difference "Workspace.count" do
      post import_workspace_data_controls_path(@workspace), params: {
        workspace_name: "Broken", workspace_slug: "broken",
        workspace_archive: Rack::Test::UploadedFile.new(file.path, "application/gzip")
      }
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /Workspace archive is invalid/
  ensure
    file&.close!
  end
end
