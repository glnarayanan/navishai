require "test_helper"

class AttachmentDownloadsControllerTest < ActionDispatch::IntegrationTest
  class CleanScanner
    def scan(**)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @attachment = create_attachment(@workspace, scanner: CleanScanner.new)
    sign_in_as users(:owner)
  end

  test "an authorized workspace member downloads an available attachment with audit" do
    assert_difference -> { AuditEvent.where(action: "attachment.downloaded").count }, 1 do
      get workspace_attachment_path(@workspace, @attachment)
    end

    assert_response :success
    assert_equal "private case file", response.body
    assert_match(/attachment; filename="note\.txt"/, response.headers["Content-Disposition"])
  end

  test "foreign and quarantined attachments fail closed" do
    foreign = create_attachment(workspaces(:beta_support), scanner: CleanScanner.new)
    quarantined = create_attachment(@workspace, scanner: AttachmentScanner.new)

    get workspace_attachment_path(@workspace, foreign)
    assert_response :not_found

    get workspace_attachment_path(@workspace, quarantined)
    assert_response :not_found
  end

  test "an unavailable object does not record a successful download" do
    @attachment.file.blob.service.delete(@attachment.file.key)

    assert_no_difference -> { AuditEvent.where(action: "attachment.downloaded").count } do
      get workspace_attachment_path(@workspace, @attachment)
    end
    assert_response :not_found
  end

  private
    def create_attachment(workspace, scanner:)
      prepared = AttachmentIntake.prepare!(
        [ { filename: "note.txt", data: "private case file" } ], scanner: scanner
      )
      AttachmentIntake.persist!(workspace: workspace, prepared: prepared, source: :inbound_email).sole
    end
end
