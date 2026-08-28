require "test_helper"

class HumanIntercomSendTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :admin_open_transactions, :admin_requests, :replies

    def initialize(error: nil)
      @error = error
      @admin_open_transactions = []
      @admin_requests = 0
      @replies = []
    end

    def admins
      @admin_open_transactions << IntercomOutboundDelivery.connection.open_transactions
      @admin_requests += 1
      { "admins" => [ { "id" => "admin_owner", "email" => "owner@example.com" } ] }
    end

    def reply(conversation_id:, admin_id:, body:)
      @replies << { conversation_id:, admin_id:, body: }
      raise @error if @error

      part_id = body == "A human reply" ? "sent_part" : "sent_part_#{Digest::SHA256.hexdigest(body).first(8)}"
      conversation(part_id: part_id, body: body, created_at: Time.current.to_i)
    end

    def conversation(_id = nil, part_id: "sent_part", body: "A human reply", created_at: Time.current.to_i)
      {
        "id" => "remote_conversation", "conversation_parts" => { "conversation_parts" => [
          {
            "id" => part_id, "part_type" => "comment", "body" => "<p>#{body}</p>",
            "created_at" => created_at,
            "author" => { "type" => "admin", "id" => "admin_owner", "name" => "Owner" }
          }
        ] }
      }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    Current.session = users(:owner).sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)
    message = ConversationThread.start_inbound!(
      workspace: @workspace, contact: contacts(:alice), subject: "Intercom help",
      body: "Please help", occurred_at: Time.zone.parse("2026-08-24 12:00:00 UTC"), source: :integration
    )
    @support_case = message.conversation.support_case
    @connection = @workspace.intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_send", credential_key: "support"
    )
    @link = @connection.intercom_conversation_links.create!(
      workspace: @workspace, conversation: message.conversation, support_case: @support_case,
      remote_conversation_id: "remote_conversation", remote_state: "open",
      source_digest: "a" * 64, remote_updated_at: message.occurred_at, synced_at: message.occurred_at
    )
    @source_part = @connection.intercom_part_links.create!(
      workspace: @workspace, intercom_conversation_link: @link, conversation: message.conversation,
      conversation_message: message, remote_part_id: "customer_part", part_type: :contact_reply,
      author_name: "Alice", body: "Please help", source_digest: "b" * 64,
      remote_created_at: message.occurred_at
    )
  end

  test "sends one exact human-attributed reply and replays the key without a second call" do
    client = FakeClient.new

    assert_difference [ "IntercomOutboundDelivery.sent.count", "ConversationMessage.outbound.count" ], 1 do
      @delivery = send_reply(client: client)
    end
    assert_no_difference [ "IntercomOutboundDelivery.count", "ConversationMessage.count" ] do
      assert_equal @delivery, send_reply(client: client)
    end

    assert @delivery.sent?
    assert_equal users(:owner), @delivery.actor_user
    assert_equal "admin_owner", @delivery.admin_id
    assert_equal "sent_part", @delivery.remote_part_id
    assert_equal "A human reply", @delivery.conversation_message.body
    assert_equal users(:owner), @delivery.conversation_message.author_user
    assert_equal 1, client.replies.size
    assert AuditEvent.where(
      action: "intercom.send_succeeded", subject_type: "IntercomOutboundDelivery",
      subject_id: @delivery.id, actor: users(:owner)
    ).exists?
  end

  test "resolves the Intercom admin outside the delivery transaction" do
    transaction_depth_before_send = IntercomOutboundDelivery.connection.open_transactions
    client = FakeClient.new

    send_reply(client: client)

    assert_equal [ transaction_depth_before_send ], client.admin_open_transactions
  end

  test "blocks unchanged blocked or needs-human source text before delivery or Intercom" do
    current_draft = nil
    %w[blocked needs_human].each do |result_state|
      artifact = create_draft_artifact(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        body: "Unsendable #{result_state} answer", result_state: result_state
      )
      draft = if current_draft
        IntercomDraftWorkflow.save!(
          workspace: @workspace, support_case: @support_case, membership: @membership,
          body: artifact.body, expected_lock_version: current_draft.reload.lock_version.to_s,
          source_crew_artifact_id: artifact.id, adopt_source: true
        )
      else
        IntercomDraftWorkflow.save!(
          workspace: @workspace, support_case: @support_case, membership: @membership,
          body: artifact.body, expected_lock_version: "new",
          source_crew_artifact_id: artifact.id, adopt_source: true
        )
      end
      client = FakeClient.new

      assert_no_difference [ "IntercomOutboundDelivery.count", "ConversationMessage.outbound.count" ] do
        error = assert_raises(ArgumentError) do
          send_reply(
            client: client, key: "unchanged-#{result_state}", body: artifact.body,
            draft_version: draft.lock_version.to_s, source_crew_artifact_id: artifact.id
          )
        end
        assert_equal HumanDraftProvenance::SEND_REVIEW_MESSAGE, error.message
      end

      assert_empty client.replies
      assert_equal 0, client.admin_requests
      assert draft.reload.ready?
      assert_equal artifact, draft.source_crew_artifact
      assert_nil draft.human_edited_at
      current_draft = draft
    end
  end

  test "sends an unchanged complete AI source without human edit attribution" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Complete generated answer", result_state: "complete"
    )
    draft = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    client = FakeClient.new

    delivery = send_reply(
      client: client, key: "complete-source", body: artifact.body,
      draft_version: draft.lock_version.to_s, source_crew_artifact_id: artifact.id
    )

    assert delivery.sent?
    assert_equal artifact, delivery.source_crew_artifact
    assert_equal "complete", delivery.generated_contract_result_state
    assert_nil delivery.human_edited_at
    assert_equal artifact.body, delivery.body
    assert_equal artifact.body, client.replies.sole[:body]
  end

  test "a blocked source cannot be sent after a human edit is reverted to the AI body" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated answer to revert", result_state: "blocked"
    )
    draft = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    edited = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Human-qualified answer", expected_lock_version: draft.lock_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    reverted = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: edited.lock_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    client = FakeClient.new

    assert reverted.human_edited_at
    refute HumanDraftProvenance.ready_for_send?(reverted)
    assert_no_difference [ "IntercomOutboundDelivery.count", "ConversationMessage.outbound.count" ] do
      error = assert_raises(ArgumentError) do
        send_reply(
          client: client, key: "reverted-source", body: artifact.body,
          draft_version: reverted.lock_version.to_s, source_crew_artifact_id: artifact.id
        )
      end
      assert_equal HumanDraftProvenance::SEND_REVIEW_MESSAGE, error.message
    end
    assert_empty client.replies
    assert_equal artifact.body, reverted.reload.body
    assert reverted.ready?
  end

  test "a stale source draft cannot overwrite or claim an Intercom delivery" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated stale-source answer", result_state: "blocked"
    )
    draft = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )
    stale_version = draft.lock_version
    current = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Current human-qualified answer", expected_lock_version: stale_version.to_s,
      source_crew_artifact_id: artifact.id
    )
    client = FakeClient.new

    assert_no_difference [ "IntercomOutboundDelivery.count", "ConversationMessage.outbound.count" ] do
      assert_raises(ActiveRecord::StaleObjectError) do
        send_reply(
          client: client, key: "stale-source", body: "Stale human answer",
          draft_version: stale_version.to_s, source_crew_artifact_id: artifact.id
        )
      end
    end
    assert_empty client.replies
    assert_equal "Current human-qualified answer", current.reload.body
    assert current.human_edited_at
  end

  test "rejects a stale source binding before the remote reply" do
    stale = HumanIntercomSend.source_part_id(workspace: @workspace, support_case: @support_case)
    add_customer_part("new_customer_part", at: Time.zone.parse("2026-08-24 12:05:00 UTC"))
    client = FakeClient.new

    assert_no_difference [ "IntercomOutboundDelivery.count", "ConversationMessage.outbound.count" ] do
      error = assert_raises(ArgumentError) { send_reply(client: client, expected_source_part_id: stale) }
      assert_match(/conversation changed/i, error.message)
    end
    assert_empty client.replies
  end

  test "a definite rejection restores the draft while a timeout needs review" do
    rejected_client = FakeClient.new(error: IntercomClient::Rejected.new("no"))
    rejected = send_reply(client: rejected_client, key: "rejected")
    assert rejected.failed?
    assert_equal "remote_rejected", rejected.failure_code
    assert rejected.intercom_draft.reload.ready?

    timeout_client = FakeClient.new(error: IntercomClient::Unavailable.new("timeout"))
    uncertain = send_reply(
      client: timeout_client, key: "uncertain",
      draft_version: rejected.intercom_draft.reload.lock_version.to_s
    )
    assert uncertain.unknown?
    assert uncertain.intercom_draft.reload.sending?

    assert_no_difference "ConversationMessage.outbound.count" do
      HumanIntercomSend.review_unknown!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        delivery: uncertain, outcome: :rejected, client: timeout_client
      )
    end
    assert uncertain.reload.failed?
    assert_equal "confirmed_not_sent", uncertain.failure_code
    assert uncertain.intercom_draft.reload.ready?
  end

  test "reviewing an accepted unknown verifies and records the remote part" do
    client = FakeClient.new(error: IntercomClient::Unavailable.new("timeout"))
    uncertain = send_reply(client: client)
    review_client = FakeClient.new

    assert_difference "ConversationMessage.outbound.count", 1 do
      HumanIntercomSend.review_unknown!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        delivery: uncertain, outcome: :accepted, remote_part_id: "sent_part", client: review_client
      )
    end

    assert uncertain.reload.sent?
    assert_equal "sent_part", uncertain.remote_part_id
    assert AuditEvent.where(
      action: "intercom.send_reviewed", subject_type: "IntercomOutboundDelivery",
      subject_id: uncertain.id, actor: users(:owner)
    ).exists?
  end

  test "accepts Intercom HTML line breaks for the exact plain-text draft" do
    client = FakeClient.new
    client.define_singleton_method(:reply) do |conversation_id:, admin_id:, body:|
      @replies << { conversation_id:, admin_id:, body: }
      response = conversation(part_id: "multiline_part", body: body, created_at: Time.current.to_i)
      response.dig("conversation_parts", "conversation_parts").sole["body"] = "<p>First line<br>Second line</p>"
      response
    end

    delivery = send_reply(client: client, body: "First line\nSecond line")

    assert delivery.sent?
    assert_equal "First line\nSecond line", delivery.conversation_message.body
  end

  test "a customer follow-up permits a fresh second human reply" do
    first = send_reply(client: FakeClient.new)
    second = travel_to(first.sent_at + 5.minutes) do
      add_customer_part("follow_up", at: Time.current)
      send_reply(
        client: FakeClient.new, key: "second", body: "Second answer",
        draft_version: first.intercom_draft.reload.lock_version.to_s,
        expected_source_part_id: "follow_up"
      )
    end

    assert second.sent?
    assert_equal "Second answer", second.body
    assert_equal 2, @support_case.conversation.conversation_messages.outbound.count
  end

  test "claim freezes artifact and edit provenance before the reusable draft becomes a follow-up" do
    artifact = create_draft_artifact(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: "Generated Intercom answer", result_state: "blocked"
    )
    draft = IntercomDraftWorkflow.save!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      body: artifact.body, expected_lock_version: "new",
      source_crew_artifact_id: artifact.id, adopt_source: true
    )

    delivery = send_reply(
      client: FakeClient.new, key: "artifact-send", body: "Human-qualified final Intercom reply",
      draft_version: draft.lock_version.to_s, source_crew_artifact_id: artifact.id
    )

    assert_equal artifact, delivery.source_crew_artifact
    assert_equal Digest::SHA256.hexdigest(artifact.body), delivery.generated_body_digest
    assert_equal "blocked", delivery.generated_contract_result_state
    assert_equal @membership, delivery.human_edited_by_membership
    assert_equal @membership.user, delivery.human_edited_by_user
    assert delivery.human_edited_at
    assert_equal "Human-qualified final Intercom reply", delivery.body
    assert_equal @membership.user, delivery.actor_user

    travel_to(delivery.sent_at + 5.minutes) do
      add_customer_part("artifact_follow_up", at: Time.current)
      IntercomDraftWorkflow.save!(
        workspace: @workspace, support_case: @support_case, membership: @membership,
        body: "New human-authored Intercom follow-up", expected_lock_version: draft.reload.lock_version.to_s
      )
    end

    assert_nil draft.reload.source_crew_artifact
    assert_nil draft.generated_body_digest
    assert_equal artifact, delivery.reload.source_crew_artifact
    assert_equal "blocked", delivery.generated_contract_result_state
    assert_equal "Human-qualified final Intercom reply", delivery.body
    assert_raises(ActiveRecord::StatementInvalid) do
      IntercomOutboundDelivery.transaction(requires_new: true) do
        IntercomOutboundDelivery.where(id: delivery.id).update_all(source_crew_artifact_id: nil)
      end
    end
  end

  test "a viewer cannot send and a key cannot cross cases" do
    viewer = User.create!(email_address: "intercom-viewer@example.com", password: "password12345", verified_at: Time.current)
    viewer_membership = @workspace.memberships.create!(user: viewer, role: :viewer)
    Current.session = viewer.sessions.create!(authentication_method: :local, expires_at: 1.hour.from_now)
    client = FakeClient.new

    assert_no_difference "IntercomOutboundDelivery.count" do
      assert_raises(Current::RoleAccessDenied) do
        send_reply(client: client, membership: viewer_membership)
      end
    end

    Current.session = users(:owner).sessions.create!(authentication_method: :local, expires_at: 1.hour.from_now)
    first = send_reply(client: client)
    other = build_other_case
    assert_raises(ActiveRecord::RecordNotFound) do
      send_reply(client: client, support_case: other, expected_source_part_id: "other_part")
    end
    assert_equal 1, client.replies.size
    assert first.sent?
  end

  test "a role or session change during preparation blocks the remote reply" do
    client = FakeClient.new
    session = Current.session
    client.define_singleton_method(:admins) do
      session.update!(expires_at: 1.minute.ago)
      super()
    end

    assert_no_difference "IntercomOutboundDelivery.count" do
      assert_raises(ActiveRecord::RecordNotFound) { send_reply(client: client) }
    end
    assert_empty client.replies
  end

  test "a role downgrade after claim blocks the Intercom reply" do
    client = FakeClient.new
    original = HumanSendAuthorization.method(:with_current_authority)
    authorization = HumanSendAuthorization.singleton_class
    membership = @membership
    downgrade_before_lock = lambda do |**arguments, &block|
      membership.update_column(:role, "viewer")
      original.call(**arguments, &block)
    end
    authorization.define_method(:with_current_authority, downgrade_before_lock)

    assert_raises(Current::RoleAccessDenied) do
      send_reply(client: client)
    end

    assert_empty client.replies
    delivery = @workspace.intercom_outbound_deliveries.sole
    assert delivery.failed?
    assert_equal "authorization_changed", delivery.failure_code
    assert delivery.intercom_draft.reload.ready?
  ensure
    authorization&.define_method(:with_current_authority, original)
  end

  test "a local failure after remote acceptance becomes unknown and keeps its durable identity" do
    other_case = build_other_case
    other_link = other_case.intercom_conversation_link
    other_message = @workspace.conversation_messages.create!(
      conversation: other_link.conversation, direction: :outbound, author_kind: :external,
      external_author_name: "Other admin", body: "A human reply", occurred_at: Time.current
    )
    @connection.intercom_part_links.create!(
      workspace: @workspace, intercom_conversation_link: other_link, conversation: other_link.conversation,
      conversation_message: other_message, remote_part_id: "sent_part", part_type: :admin_reply,
      body: "A human reply", source_digest: "e" * 64, remote_created_at: Time.current
    )
    client = FakeClient.new

    assert_no_difference "ConversationMessage.outbound.count" do
      assert_raises(ActiveRecord::RecordNotFound) { send_reply(client: client) }
    end
    delivery = @workspace.intercom_outbound_deliveries.sole
    assert delivery.unknown?
    assert_equal "unknown_outcome", delivery.failure_code
    assert_equal 1, client.replies.size

    assert_raises(ActiveRecord::StatementInvalid) do
      IntercomOutboundDelivery.connection.execute(
        "UPDATE intercom_outbound_deliveries SET id = id + 1000000 WHERE id = #{delivery.id}"
      )
    end
  end

  private
    def send_reply(client:, key: "send-key", body: "A human reply", draft_version: "new",
      source_crew_artifact_id: nil, expected_source_part_id: @source_part.remote_part_id,
      membership: @membership, support_case: @support_case)
      HumanIntercomSend.send!(
        workspace: @workspace, support_case: support_case, membership: membership,
        body: body, draft_version: draft_version, idempotency_key: key,
        source_crew_artifact_id: source_crew_artifact_id,
        expected_source_part_id: expected_source_part_id, client: client
      )
    end

    def add_customer_part(id, at:)
      message = ConversationThread.append_inbound!(
        workspace: @workspace, conversation: @link.conversation, author: @link.conversation.contact,
        body: "Customer follow-up", occurred_at: at, source: :integration
      )
      @connection.intercom_part_links.create!(
        workspace: @workspace, intercom_conversation_link: @link, conversation: @link.conversation,
        conversation_message: message, remote_part_id: id, part_type: :contact_reply,
        author_name: "Alice", body: message.body, source_digest: Digest::SHA256.hexdigest(id), remote_created_at: at
      )
    end

    def build_other_case
      message = ConversationThread.start_inbound!(
        workspace: @workspace, contact: contacts(:alice), subject: "Other",
        body: "Other case", occurred_at: Time.current, source: :integration
      )
      link = @connection.intercom_conversation_links.create!(
        workspace: @workspace, conversation: message.conversation, support_case: message.conversation.support_case,
        remote_conversation_id: "other", remote_state: "open", source_digest: "c" * 64,
        remote_updated_at: Time.current, synced_at: Time.current
      )
      @connection.intercom_part_links.create!(
        workspace: @workspace, intercom_conversation_link: link, conversation: link.conversation,
        conversation_message: message, remote_part_id: "other_part", part_type: :contact_reply,
        body: message.body, source_digest: "d" * 64, remote_created_at: message.occurred_at
      )
      link.support_case
    end
end
