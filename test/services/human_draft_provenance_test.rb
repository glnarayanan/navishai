require "test_helper"

class HumanDraftProvenanceTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @inbox = @workspace.shared_email_inboxes.create!(
      name: "Draft authority", email_address: "drafts@example.com", credential_key: "drafts"
    )
    intake = SharedEmailIntake.receive!(
      inbox: @inbox, raw_email: raw_email,
      received_at: Time.zone.parse("2026-08-27 12:00:00 UTC")
    )
    @support_case = intake.conversation.support_case
    @connection = @workspace.intercom_connections.create!(
      name: "Draft authority", remote_workspace_id: "draft_authority", credential_key: "drafts"
    )
    @link = @connection.intercom_conversation_links.create!(
      workspace: @workspace, conversation: @support_case.conversation, support_case: @support_case,
      remote_conversation_id: "draft_authority", remote_state: "open", source_digest: "a" * 64,
      remote_updated_at: Time.current, synced_at: Time.current
    )
  end

  test "email adopts only the exact artifact body and freezes its generated proof" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated exact answer", result_state: "needs_human"
    )

    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )

    assert_equal artifact, draft.source_crew_artifact
    assert_equal Digest::SHA256.hexdigest(artifact.body), draft.generated_body_digest
    assert_equal "needs_human", draft.generated_contract_result_state
    assert_nil draft.human_edited_at

    unchanged = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: draft.lock_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    assert_nil unchanged.human_edited_at

    error = assert_raises(ArgumentError) do
      EmailDraftWorkflow.save!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        body: "Not the artifact body", expected_lock_version: unchanged.lock_version.to_s,
        source_crew_artifact_id: artifact.id, adopt_source: true
      )
    end
    assert_match(/body changed/i, error.message)
  end

  test "email records the first human edit actor and time without changing the artifact" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated answer"
    )
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    editor = User.create!(
      email_address: "draft-editor@example.com", password: "password12345", verified_at: Time.current
    )
    editor_membership = @workspace.memberships.create!(user: editor, role: :member)
    edited_at = Time.zone.parse("2026-08-27 13:00:00 UTC")

    edited = travel_to(edited_at) do
      EmailDraftWorkflow.save!(
        workspace: @workspace, support_case: @support_case, membership: editor_membership,
        body: "Qualified human answer", expected_lock_version: draft.lock_version.to_s,
        source_crew_artifact_id: artifact.id
      )
    end

    assert_equal editor_membership, edited.human_edited_by_membership
    assert_equal editor, edited.human_edited_by_user
    assert_equal edited_at, edited.human_edited_at
    assert_equal "Generated answer", artifact.reload.body
    assert_equal Digest::SHA256.hexdigest("Generated answer"), edited.generated_body_digest

    saved_again = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Owner revised the qualified answer", expected_lock_version: edited.lock_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    assert_equal editor, saved_again.human_edited_by_user
    assert_equal edited_at, saved_again.human_edited_at
    assert_equal "Owner revised the qualified answer", saved_again.body
  end

  test "human-authored email drafts remain valid without source provenance" do
    draft = EmailDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Entirely human answer", expected_lock_version: "new"
    )

    assert_nil draft.source_crew_artifact
    assert_nil draft.generated_body_digest
    assert_nil draft.generated_contract_result_state
    assert_nil draft.human_edited_at
  end

  test "Intercom has the same adoption edit and stale-write rules" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated Intercom answer", result_state: "blocked"
    )
    draft = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    stale_version = draft.lock_version

    edited = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Human-qualified Intercom answer", expected_lock_version: stale_version.to_s,
      source_crew_artifact_id: artifact.id
    )

    assert_equal artifact, edited.source_crew_artifact
    assert_equal "blocked", edited.generated_contract_result_state
    assert_equal @membership.user, edited.human_edited_by_user
    assert edited.human_edited_at
    assert_raises(ActiveRecord::StaleObjectError) do
      IntercomDraftWorkflow.save!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        body: "Stale edit", expected_lock_version: stale_version.to_s,
        source_crew_artifact_id: artifact.id
      )
    end
    assert_equal "Human-qualified Intercom answer", edited.reload.body
  end

  test "source selection fails closed for wrong case kind Workspace and malformed IDs" do
    wrong_case = create_support_case(workspace: @workspace, membership: @membership)
    add_inbound_message(wrong_case)
    wrong_case_artifact = create_draft_artifact(
      workspace: @workspace, support_case: wrong_case, membership: @membership
    )
    wrong_kind = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      artifact_kind: "investigation"
    )
    beta_workspace = workspaces(:beta_support)
    beta_membership = memberships(:outsider_beta)
    beta_case = create_support_case(
      workspace: beta_workspace, contact: contacts(:bob), membership: beta_membership
    )
    add_inbound_message(beta_case)
    foreign_artifact = create_draft_artifact(
      workspace: beta_workspace, support_case: beta_case, membership: beta_membership
    )

    [ wrong_case_artifact.id, wrong_kind.id, foreign_artifact.id, "-1", "abc", "9" * 20 ].each do |source_id|
      assert_no_difference "EmailDraft.count" do
        assert_raises(ActiveRecord::RecordNotFound) do
          EmailDraftWorkflow.save!(
            workspace: @workspace, support_case: @support_case, membership: @membership,
            body: "Generated answer", expected_lock_version: "new",
            source_crew_artifact_id: source_id, adopt_source: true
          )
        end
      end
    end
  end

  private
    def raw_email
      [
        "From: Alice Example <alice@example.net>",
        "To: Drafts <drafts@example.com>",
        "Date: Thu, 27 Aug 2026 11:55:00 +0000",
        "Subject: Draft authority",
        "Message-ID: <draft-authority@example.net>",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "Please help"
      ].join("\r\n")
    end
end
