require "test_helper"

class IntercomSyncTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:pages, :conversation_requests, keyword_init: true) do
    def conversation(id)
      conversation_requests << id
      pages.fetch(id) { raise IntercomClient::Unavailable, "offline" }
    end

    def conversations(starting_after: nil)
      { "conversations" => pages.values.map { |remote| { "id" => remote.fetch("id") } }, "pages" => { "next" => nil } }
    end

    def admins
      { "admins" => [ { "id" => "admin_1", "name" => "Team one" } ] }
    end

    def teams
      { "teams" => [ { "id" => "team_1", "name" => "Support team" } ] }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @connection = @workspace.intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_123", credential_key: "support"
    )
    @client = FakeClient.new(pages: {}, conversation_requests: [])
  end

  test "replays a signed notification idempotently" do
    raw = notification("contact.user.created", {
      "type" => "contact", "id" => "contact_1", "email" => "intercom-alice@example.net", "name" => "Alice"
    })

    assert_difference [ "Contact.count", "SourceIdentity.count" ], 1 do
      first = IntercomSync.receive!(connection: @connection, raw_payload: raw, client: @client)
      second = IntercomSync.receive!(connection: @connection, raw_payload: raw, client: @client)
      assert_equal first, second
      assert first.processed?
    end
    assert_equal 1, @connection.intercom_webhook_deliveries.count
  end

  test "does not process a delivery after its connection is paused" do
    @connection.update!(active: false)
    raw = notification("contact.user.created", {
      "type" => "contact", "id" => "contact_paused", "email" => "paused@example.net", "name" => "Paused"
    })

    assert_raises IntercomSync::InvalidPayload do
      IntercomSync.receive!(connection: @connection, raw_payload: raw, client: @client)
    end

    delivery = @connection.intercom_webhook_deliveries.sole
    assert delivery.failed?
    assert_equal "invalid_payload", delivery.failure_code
    assert_nil @workspace.source_identities.find_by(source_record_id: "contact_paused")
  end

  test "keeps an ambiguous identity and failed delivery together for review" do
    alice = @workspace.contacts.create!(name: "Alice")
    bob = @workspace.contacts.create!(name: "Bob")
    create_matched_identity(alice, "manual_alice", "shared@example.net")
    create_matched_identity(bob, "manual_bob", "shared@example.net")
    raw = notification("contact.user.created", {
      "type" => "contact", "id" => "contact_ambiguous", "email" => "shared@example.net", "name" => "Shared"
    })

    delivery = IntercomSync.receive!(connection: @connection, raw_payload: raw, client: @client)

    assert delivery.failed?
    assert_equal "identity_ambiguous", delivery.failure_code
    identity = @workspace.source_identities.find_by!(
      source_namespace: "intercom:#{@connection.id}", source_record_id: "contact_ambiguous"
    )
    assert identity.ambiguous?
    assert_equal [ alice.id, bob.id ], identity.identity_match_candidates.order(:contact_id).pluck(:contact_id)
    assert_includes @connection.intercom_webhook_deliveries.retryable, delivery
  end

  test "creates a case and reconciles conversation drift without duplicating parts" do
    remote = remote_conversation(updated_at: 100, state: "open", tags: [ { "id" => "tag_1", "name" => "Billing" } ])
    @client.pages["conversation_1"] = remote

    assert_difference [ "Conversation.count", "SupportCase.count" ], 1 do
      IntercomSync.receive!(
        connection: @connection,
        raw_payload: notification("conversation.user.created", remote),
        client: @client
      )
    end
    link = @connection.intercom_conversation_links.sole
    assert_equal 3, link.intercom_part_links.count
    assert_equal [ "Billing" ], link.support_case.tags.pluck(:name)
    assert_equal "Team one", link.remote_assignee_name
    assert_equal "Please help", link.conversation.conversation_messages.first.body

    @client.pages["conversation_1"] = remote_conversation(updated_at: 200, state: "closed", tags: [])
    assert_equal 1, IntercomSync.reconcile!(connection: @connection, client: @client)

    assert_equal "closed", link.reload.remote_state
    assert_empty link.support_case.tags
    assert_equal 3, link.intercom_part_links.count
    assert_equal [ "conversation_1", "conversation_1" ], @client.conversation_requests
  end

  test "does not remove a human-owned tag that shares a remote tag name" do
    local_tag = @workspace.tags.create!(name: "VIP")
    remote = remote_conversation(updated_at: 100, state: "open", tags: [])
    @client.pages["conversation_1"] = remote
    IntercomSync.receive!(
      connection: @connection, raw_payload: notification("conversation.user.created", remote), client: @client
    )
    synced_case = @connection.intercom_conversation_links.sole.support_case
    human_tagging = @workspace.support_case_taggings.create!(support_case: synced_case, tag: local_tag)

    @client.pages["conversation_1"] = remote_conversation(
      updated_at: 200, state: "open", tags: [ { "id" => "remote_vip", "name" => "VIP" } ]
    )
    IntercomSync.reconcile!(connection: @connection, client: @client)
    assert_nil human_tagging.reload.source_intercom_connection_id

    @client.pages["conversation_1"] = remote_conversation(updated_at: 300, state: "open", tags: [])
    IntercomSync.reconcile!(connection: @connection, client: @client)

    assert synced_case.tags.exists?(local_tag.id)
    assert_nil human_tagging.reload.source_intercom_connection_id
  end

  test "syncs team assignment from the Intercom API fields" do
    remote = remote_conversation(updated_at: 100, state: "open", tags: [])
    remote["admin_assignee_id"] = 0
    remote["team_assignee_id"] = "team_1"
    @client.pages["conversation_1"] = remote

    IntercomSync.receive!(
      connection: @connection,
      raw_payload: notification("conversation.user.created", remote),
      client: @client
    )

    link = @connection.intercom_conversation_links.sole
    assert_equal "team_1", link.remote_assignee_id
    assert_equal "Support team", link.remote_assignee_name
  end

  test "links the conversation contact to its Intercom company" do
    remote = remote_conversation(updated_at: 100, state: "open", tags: [])
    remote["company"] = {
      "id" => "company_1", "name" => "Example Corp", "website" => "https://example.com/about"
    }
    @client.pages["conversation_1"] = remote

    IntercomSync.receive!(
      connection: @connection,
      raw_payload: notification("conversation.user.created", remote),
      client: @client
    )

    contact = @connection.intercom_conversation_links.sole.conversation.contact
    assert_equal "Example Corp", contact.account.name
    assert_equal "example.com", contact.account.source_identities.sole.source_identity_keys.sole.normalized_value
  end

  test "keeps an admin-initiated source outbound and the customer reply inbound" do
    remote = remote_conversation(updated_at: 100, state: "open", tags: [])
    remote["source"]["author"] = { "type" => "admin", "name" => "Support teammate" }
    remote["conversation_parts"]["conversation_parts"] = []
    @client.pages["conversation_1"] = remote

    IntercomSync.receive!(
      connection: @connection,
      raw_payload: notification("conversation.admin.single.created", remote),
      client: @client
    )

    link = @connection.intercom_conversation_links.sole
    source_message = link.conversation.conversation_messages.sole
    assert source_message.outbound?
    assert source_message.external?
    assert_equal "Support teammate", source_message.external_author_name
    assert_nil link.support_case.case_sla

    remote["updated_at"] = 110
    remote["conversation_parts"]["conversation_parts"] = [ {
      "id" => "customer_reply", "part_type" => "comment", "created_at" => 105, "body" => "I still need help",
      "author" => { "type" => "contact", "name" => "Bob" }
    } ]
    @client.pages["conversation_1"] = remote
    IntercomSync.reconcile!(connection: @connection, client: @client)

    assert link.conversation.conversation_messages.reload.last.inbound?
  end

  test "resumes reconciliation from Intercom URL cursors" do
    first = remote_conversation(updated_at: 100, state: "open", tags: [])
    second = remote_conversation(updated_at: 200, state: "closed", tags: []).merge("id" => "conversation_2")
    second["source"] = second.fetch("source").merge("id" => "source_2")
    second.dig("conversation_parts", "conversation_parts").each_with_index do |part, index|
      part["id"] = "part_#{index + 3}"
    end
    client = @client
    client.pages["conversation_1"] = first
    client.pages["conversation_2"] = second
    client.define_singleton_method(:conversations) do |starting_after: nil|
      if starting_after
        { "conversations" => [ { "id" => "conversation_2" } ], "pages" => { "next" => nil } }
      else
        {
          "conversations" => [ { "id" => "conversation_1" } ],
          "pages" => { "next" => "https://api.intercom.io/conversations?starting_after=next_page" }
        }
      end
    end

    assert_equal 1, IntercomSync.reconcile!(connection: @connection, client: client, limit: 1)
    assert_equal "next_page", @connection.reload.reconciliation_cursor
    assert_equal 1, IntercomSync.reconcile!(connection: @connection, client: client, limit: 1)

    assert_nil @connection.reload.reconciliation_cursor
    assert_equal %w[conversation_1 conversation_2], client.conversation_requests
  end

  test "ignores an older conversation snapshot" do
    current = remote_conversation(updated_at: 200, state: "closed", tags: [])
    @client.pages["conversation_1"] = current
    IntercomSync.receive!(
      connection: @connection,
      raw_payload: notification("conversation.user.created", current),
      client: @client
    )
    link = @connection.intercom_conversation_links.sole

    older = remote_conversation(updated_at: 100, state: "open", tags: [])
    older.dig("contacts", "contacts").first["name"] = "Old Bob"
    @client.pages["conversation_1"] = older
    IntercomSync.reconcile!(connection: @connection, client: @client)

    assert_equal "closed", link.reload.remote_state
    assert_equal Time.zone.at(200), link.remote_updated_at
    assert_equal "Bob", link.conversation.contact.name
  end

  test "retries a transient webhook with an attributable audit" do
    raw = JSON.generate(
      type: "notification_event", id: "notification_retry", app_id: "app_123",
      topic: "conversation.user.replied",
      data: { item: { type: "conversation_part", id: "part_retry", conversation_id: "conversation_1" } }
    )
    delivery = IntercomSync.receive!(connection: @connection, raw_payload: raw, client: @client)
    assert delivery.failed?
    assert_equal "remote_unavailable", delivery.failure_code

    @client.pages["conversation_1"] = remote_conversation(updated_at: 100, state: "open", tags: [])
    retried = IntercomSync.retry!(
      connection: @connection, membership: memberships(:owner_support), client: @client
    )

    assert_equal [ delivery ], retried
    assert delivery.reload.processed?
    assert_equal 2, delivery.attempt_count
    assert AuditEvent.where(action: "intercom.webhook_retried", subject_id: delivery.id, actor: users(:owner)).exists?
  end

  test "retires a deleted contact identity and its match keys" do
    created = notification("contact.user.created", {
      "type" => "contact", "id" => "contact_delete", "email" => "retire@example.net", "name" => "Retire"
    })
    IntercomSync.receive!(connection: @connection, raw_payload: created, client: @client)
    identity = @workspace.source_identities.find_by!(source_record_id: "contact_delete")

    deleted = JSON.generate(
      type: "notification_event", id: "notification_delete", app_id: "app_123",
      topic: "contact.deleted", data: { item: { type: "contact", id: "contact_delete" } }
    )
    IntercomSync.receive!(connection: @connection, raw_payload: deleted, client: @client)

    assert identity.reload.retired_at?
    assert_empty identity.source_identity_keys.current
  end

  test "marks a redacted part without changing the retained source" do
    remote = remote_conversation(updated_at: 100, state: "open", tags: [])
    @client.pages["conversation_1"] = remote
    IntercomSync.receive!(
      connection: @connection,
      raw_payload: notification("conversation.user.created", remote),
      client: @client
    )
    part = @connection.intercom_part_links.find_by!(remote_part_id: "part_1")
    original_body = part.body
    redaction = notification("conversation_part.redacted", {
      "type" => "conversation_part", "id" => "part_1", "updated_at" => 200
    })

    IntercomSync.receive!(connection: @connection, raw_payload: redaction, client: @client)

    assert_equal Time.zone.at(200), part.reload.redacted_at
    assert_equal original_body, part.body
  end

  test "marks a deleted conversation source without deleting local history" do
    remote = remote_conversation(updated_at: 100, state: "open", tags: [])
    @client.pages["conversation_1"] = remote
    IntercomSync.receive!(
      connection: @connection,
      raw_payload: notification("conversation.user.created", remote),
      client: @client
    )
    link = @connection.intercom_conversation_links.sole
    deleted = notification("conversation.deleted", { "type" => "conversation", "id" => "conversation_1" })

    IntercomSync.receive!(connection: @connection, raw_payload: deleted, client: @client)

    assert_equal "deleted", link.reload.remote_state
    assert link.conversation.persisted?
    assert link.support_case.persisted?
  end

  private
    def create_matched_identity(contact, source_record_id, email)
      identity = @workspace.source_identities.create!(
        entity_kind: :contact, source_namespace: "manual_import", source_record_type: :contact,
        source_record_id: source_record_id, status: :matched, contact: contact,
        resolution_method: :created, resolved_at: Time.current
      )
      identity.source_identity_keys.create!(workspace: @workspace, kind: :email, normalized_value: email)
    end

    def notification(topic, item)
      JSON.generate(
        type: "notification_event", id: "notification_#{topic}", app_id: "app_123",
        topic: topic, created_at: 100, data: { item: item }
      )
    end

    def remote_conversation(updated_at:, state:, tags:)
      {
        "type" => "conversation", "id" => "conversation_1", "created_at" => 90,
        "updated_at" => updated_at, "state" => state, "title" => "Billing help",
        "contacts" => { "contacts" => [
          { "type" => "contact", "id" => "contact_2", "email" => "intercom-bob@example.net", "name" => "Bob" }
        ] },
        "source" => {
          "id" => "source_1", "part_type" => "contact_reply", "created_at" => 90,
          "body" => "<p>Please <strong>help</strong></p>", "author" => { "type" => "contact", "name" => "Bob" }
        },
        "conversation_parts" => { "conversation_parts" => [
          {
            "id" => "part_1", "part_type" => "comment", "created_at" => 95, "body" => "More detail",
            "author" => { "type" => "contact", "name" => "Bob" }
          },
          {
            "id" => "part_2", "part_type" => "note", "created_at" => 96, "body" => "Internal note",
            "author" => { "type" => "admin", "name" => "Teammate" }
          }
        ] },
        "admin_assignee_id" => "admin_1", "team_assignee_id" => 0,
        "tags" => { "tags" => tags }
      }
    end
end
