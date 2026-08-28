require "test_helper"

class IntercomHistoricalBackfillTest < ActiveSupport::TestCase
  CleanScanner = Class.new do
    def scan(data:, content_type:, filename:)
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
  end

  FakeClient = Struct.new(:remotes, :attachment_bodies, :requests, :fail_after, keyword_init: true) do
    def conversations(starting_after: nil)
      requests << [ :conversations, starting_after ]
      { "conversations" => remotes.values.map { |remote| { "id" => remote.fetch("id") } }, "pages" => { "next" => nil } }
    end

    def conversation(id)
      requests << [ :conversation, id ]
      raise IntercomClient::Unavailable, "interrupted" if fail_after && requests.count { |kind, _| kind == :conversation } > fail_after

      Marshal.load(Marshal.dump(remotes.fetch(id)))
    end

    def attachment(url)
      requests << [ :attachment, url ]
      attachment_bodies.fetch(url)
    end

    def admins = { "admins" => [] }
    def teams = { "teams" => [] }

    %i[add_note reply assign tag untag create_tag].each do |method_name|
      define_method(method_name) { |**| raise "remote mutation attempted: #{method_name}" }
    end

    def assert_get_only!
      requests.all? { |kind, _| %i[conversations conversation attachment].include?(kind) }
    end
  end

  class FailingQueueAdapter
    def enqueue(*) = raise ActiveJob::EnqueueError, "queue offline"
    def enqueue_at(*) = raise ActiveJob::EnqueueError, "queue offline"
  end

  setup do
    @workspace = workspaces(:acme_support)
    @connection = @workspace.intercom_connections.create!(
      name: "Historical Intercom", remote_workspace_id: "history_app", credential_key: "history"
    )
    @owner = memberships(:owner_support)
    @remote = remote_conversation
    @client = FakeClient.new(
      remotes: { @remote.fetch("id") => @remote },
      attachment_bodies: { "https://files.intercom.test/history.txt" => "Historical file" }, requests: []
    )
  end

  test "dry run persists a bounded exact manifest without customer writes or remote writes" do
    customer_counts = customer_counts()

    manifest = IntercomHistoricalBackfill.preview!(
      connection: @connection, membership: @owner, client: @client, discovered_at: Time.zone.at(500)
    )

    assert_equal customer_counts, customer_counts()
    assert manifest.current?
    assert_equal 1, manifest.counts.fetch("conversations")
    assert_equal 3, manifest.counts.fetch("parts")
    assert_equal 1, manifest.counts.fetch("notes")
    assert_equal 1, manifest.counts.fetch("attachments")
    assert_equal Time.zone.at(90), manifest.available_from
    assert_equal Time.zone.at(100), manifest.available_to
    assert_equal 64, manifest.source_digest.length
    assert_operator manifest.discovery_records.to_json.bytesize, :<=, IntercomBackfillManifest::MAX_DISCOVERY_BYTES
    assert_equal 1, AuditEvent.where(action: "intercom.backfill_previewed", subject_id: manifest.id).count
    assert @client.assert_get_only!
  end

  test "confirmation rejects stale or changed manifests before customer writes" do
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    before = customer_counts()
    @client.remotes.fetch("conversation_history")["updated_at"] = 101

    assert_raises IntercomHistoricalBackfill::StaleManifest do
      IntercomHistoricalBackfill.confirm!(
        connection: @connection, manifest:, membership: @owner, client: @client
      )
    end

    assert_equal before, customer_counts()
    assert manifest.reload.stale?
    assert_empty @workspace.intercom_backfill_runs
  end

  test "confirmation and resume require a current integration admin and exact unconsumed manifest" do
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    member = @workspace.memberships.create!(user: users(:teammate), role: :member)

    assert_raises(Current::RoleAccessDenied) do
      IntercomHistoricalBackfill.confirm!(
        connection: @connection, manifest:, membership: member, client: @client, enqueue: false
      )
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      IntercomHistoricalBackfill.confirm!(
        connection: @connection, manifest:, membership: memberships(:outsider_beta), client: @client, enqueue: false
      )
    end
    assert_raises(IntercomHistoricalBackfill::StaleManifest) do
      IntercomHistoricalBackfill.confirm!(
        connection: @connection, manifest:, membership: @owner, client: @client,
        expected_digest: "0" * 64, enqueue: false
      )
    end

    run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false
    )
    assert_raises(IntercomHistoricalBackfill::StaleManifest) do
      IntercomHistoricalBackfill.confirm!(
        connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false
      )
    end
    run.update!(status: :failed, failure_code: "remote_unavailable")
    IntercomHistoricalBackfill.resume!(run:, membership: @owner, client: @client, enqueue: false)
    assert_raises(ArgumentError) do
      IntercomHistoricalBackfill.resume!(run:, membership: @owner, client: @client, enqueue: false)
    end
    assert @client.assert_get_only!
  end

  test "confirmed batches preserve history and attachments and replay idempotently" do
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false
    )

    assert_difference [ "Conversation.count", "IntercomConversationLink.count" ], 1 do
      IntercomHistoricalBackfill.perform!(run:, client: @client, batch_size: 1, scanner: CleanScanner.new)
    end
    assert_no_difference [ "Conversation.count", "IntercomConversationLink.count" ] do
      IntercomHistoricalBackfill.perform!(run: run.reload, client: @client, batch_size: 1, scanner: CleanScanner.new)
    end

    assert run.reload.completed?
    assert_equal "conversation_history", run.last_definite_remote_id
    assert_equal 1, run.intercom_backfill_batches.count
    report = run.intercom_backfill_report
    assert report.complete?
    assert_equal 1, report.counts.fetch("discovered")
    assert_equal 1, report.counts.fetch("imported")
    assert_equal 0, report.counts.fetch("pending")
    assert report.reconciled?
    link = @connection.intercom_conversation_links.find_by!(remote_conversation_id: "conversation_history")
    assert_equal Time.zone.at(90), link.conversation.started_at
    assert_equal %w[contact_reply note admin_reply], link.intercom_part_links.order(:remote_created_at).pluck(:part_type)
    note = link.intercom_part_links.find_by!(part_type: :note)
    attachment = note.stored_attachments.sole
    assert_equal "Historical file", attachment.download_verified!
    assert attachment.available?
    assert_equal "intercom_import", attachment.source
    assert_equal Time.zone.at(96), note.remote_created_at
    assert @client.assert_get_only!
  end

  test "interruption resumes only after the last committed record" do
    second = Marshal.load(Marshal.dump(remote_conversation)).merge("id" => "conversation_second", "updated_at" => 110)
    second["source"] = second.fetch("source").merge("id" => "source_second")
    second.dig("conversation_parts", "conversation_parts").each { |part| part["id"] = "second_#{part.fetch('id')}" }
    @client.remotes[second.fetch("id")] = second
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false)
    @client.fail_after = 5

    IntercomHistoricalBackfill.perform!(run:, client: @client, batch_size: 1, scanner: CleanScanner.new)
    IntercomHistoricalBackfill.perform!(run: run.reload, client: @client, batch_size: 1, scanner: CleanScanner.new)

    assert run.reload.failed?
    assert_equal 1, run.cursor_position
    assert_equal "conversation_history", run.last_definite_remote_id
    @client.fail_after = nil
    IntercomHistoricalBackfill.resume!(run:, membership: @owner, client: @client, enqueue: false)
    IntercomHistoricalBackfill.perform!(run: run.reload, client: @client, batch_size: 1, scanner: CleanScanner.new)
    assert run.reload.completed?
    assert_equal 2, @connection.intercom_conversation_links.count
  end

  test "changed or ambiguous record stops for recoverable review without advancing" do
    alice = @workspace.contacts.create!(name: "One")
    bob = @workspace.contacts.create!(name: "Two")
    create_identity(alice, "one", "shared-history@example.net")
    create_identity(bob, "two", "shared-history@example.net")
    @remote.dig("contacts", "contacts").first["email"] = "shared-history@example.net"
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false)

    IntercomHistoricalBackfill.perform!(run:, client: @client, scanner: CleanScanner.new)

    assert run.reload.blocked?
    assert_equal 0, run.cursor_position
    exception = run.intercom_backfill_exceptions.find_by!(exception_kind: "ambiguous_identity")
    assert_equal "review_identity", exception.recovery_action
    assert exception.source_identity.ambiguous?
    assert_empty @connection.intercom_conversation_links
  end

  test "unsupported and rejected attachments are bounded exceptions and preserve the conversation" do
    @remote.dig("conversation_parts", "conversation_parts").first["attachments"] << {
      "id" => "bad_file", "name" => "bad.bin", "url" => "https://files.intercom.test/bad.bin"
    }
    @client.attachment_bodies["https://files.intercom.test/bad.bin"] = "\x00\x01".b
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false)

    IntercomHistoricalBackfill.perform!(run:, client: @client, scanner: CleanScanner.new)

    assert run.reload.completed?
    exception = run.intercom_backfill_exceptions.find_by!(exception_kind: "attachment_rejected")
    assert_equal "inspect_attachment", exception.recovery_action
    assert_operator exception.detail.bytesize, :<=, IntercomBackfillException::MAX_DETAIL_BYTES
    assert_equal %w[available rejected], @workspace.stored_attachments.order(:id).pluck(:scan_status)
    assert_equal 1, run.intercom_backfill_report.counts.fetch("unsupported")
  end

  test "historical deletion and redaction markers remain attached to preserved source records" do
    @remote["state"] = "deleted"
    redacted = @remote.dig("conversation_parts", "conversation_parts").first
    redacted["redacted"] = true
    redacted["updated_at"] = 99
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false
    )

    IntercomHistoricalBackfill.perform!(run:, client: @client, scanner: CleanScanner.new)

    link = @connection.intercom_conversation_links.find_by!(remote_conversation_id: "conversation_history")
    assert_equal "deleted", link.remote_state
    assert_equal Time.zone.at(99), link.intercom_part_links.find_by!(remote_part_id: "note_history").redacted_at
    assert_equal "Private note", link.intercom_part_links.find_by!(remote_part_id: "note_history").body
  end

  test "an older source snapshot is counted as skipped without overwriting newer local history" do
    first_manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    first_run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest: first_manifest, membership: @owner, client: @client, enqueue: false
    )
    IntercomHistoricalBackfill.perform!(run: first_run, client: @client, scanner: CleanScanner.new)
    link = @connection.intercom_conversation_links.sole
    link.update!(remote_updated_at: Time.zone.at(200), remote_state: "newer-local-state")

    second_manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    second_run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest: second_manifest, membership: @owner, client: @client, enqueue: false
    )
    IntercomHistoricalBackfill.perform!(run: second_run, client: @client, scanner: CleanScanner.new)

    assert_equal 1, second_run.reload.intercom_backfill_report.counts.fetch("skipped")
    assert_equal 0, second_run.intercom_backfill_report.counts.fetch("imported")
    assert_equal "newer-local-state", link.reload.remote_state
  end

  test "discovery stops at the fixed conversation boundary without persisting a manifest" do
    remotes = (1..(IntercomHistoricalBackfill::MAX_RECORDS + 1)).to_h do |index|
      remote = Marshal.load(Marshal.dump(remote_conversation)).merge("id" => "history-#{index}")
      [ remote.fetch("id"), remote ]
    end
    client = FakeClient.new(remotes:, attachment_bodies: {}, requests: [])

    assert_no_difference "IntercomBackfillManifest.count" do
      error = assert_raises(IntercomHistoricalBackfill::BoundaryChanged) do
        IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client:)
      end
      assert_match(/500 conversation limit/, error.message)
    end
    assert_equal IntercomHistoricalBackfill::MAX_RECORDS, client.requests.count { |kind, _| kind == :conversation }
    assert client.assert_get_only!
  end

  test "record failure after attachment persistence rolls back target objects and retries as one truthful import" do
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false
    )
    source_before = Marshal.load(Marshal.dump(@client.remotes))
    attachment_source_before = @client.attachment_bodies.transform_values(&:dup)
    before_counts = [ Conversation.count, StoredAttachment.count, ActiveStorage::Blob.count ]
    before_objects = attachment_storage_objects
    install_attachment_link_failure

    IntercomHistoricalBackfill.perform!(run:, client: @client, batch_size: 1, scanner: CleanScanner.new)

    assert run.reload.failed?
    assert_equal 0, run.cursor_position
    assert_equal before_counts, [ Conversation.count, StoredAttachment.count, ActiveStorage::Blob.count ]
    assert_equal before_objects, attachment_storage_objects
    assert_empty @connection.intercom_conversation_links.reload
    assert_equal source_before, @client.remotes
    assert_equal attachment_source_before, @client.attachment_bodies
    remove_attachment_link_failure

    IntercomHistoricalBackfill.resume!(run:, membership: @owner, client: @client, enqueue: false)
    IntercomHistoricalBackfill.perform!(run: run.reload, client: @client, batch_size: 1, scanner: CleanScanner.new)

    report = run.reload.intercom_backfill_report
    assert run.completed?
    assert_equal 1, report.counts.fetch("imported")
    assert_equal 0, report.counts.fetch("matched")
    assert_equal 1, @connection.intercom_conversation_links.count
    assert_equal 1, @workspace.intercom_part_attachments.count
    new_objects = attachment_storage_objects - before_objects
    assert_equal 1, new_objects.size
    assert_equal "Historical file", File.binread(new_objects.sole)
    assert_equal source_before, @client.remotes
    assert_equal attachment_source_before, @client.attachment_bodies
    assert @client.assert_get_only!
  ensure
    remove_attachment_link_failure
  end

  test "confirmation enqueue failure is durable and resumable without repeating remote writes" do
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    original_adapter = IntercomBackfillJob.queue_adapter
    IntercomBackfillJob.queue_adapter = FailingQueueAdapter.new

    run = IntercomHistoricalBackfill.confirm!(
      connection: @connection, manifest:, membership: @owner, client: @client, enqueue: true
    )

    assert run.reload.failed?
    assert_equal "enqueue_error", run.failure_code
    assert manifest.reload.consumed?
    assert_equal 0, run.cursor_position
    IntercomBackfillJob.queue_adapter = original_adapter
    IntercomHistoricalBackfill.resume!(run:, membership: @owner, client: @client, enqueue: false)
    IntercomHistoricalBackfill.perform!(run: run.reload, client: @client, scanner: CleanScanner.new)
    assert run.reload.completed?
    assert_equal 1, run.intercom_backfill_report.counts.fetch("imported")
    assert @client.assert_get_only!
  ensure
    IntercomBackfillJob.queue_adapter = original_adapter if original_adapter
  end

  test "batch enqueue failure resumes after its last definite cursor" do
    second = Marshal.load(Marshal.dump(remote_conversation)).merge("id" => "conversation_second")
    second["source"] = second.fetch("source").merge("id" => "source_second")
    second.dig("conversation_parts", "conversation_parts").each { |part| part["id"] = "second_#{part.fetch('id')}" }
    @client.remotes[second.fetch("id")] = second
    manifest = IntercomHistoricalBackfill.preview!(connection: @connection, membership: @owner, client: @client)
    run = IntercomHistoricalBackfill.confirm!(connection: @connection, manifest:, membership: @owner, client: @client, enqueue: false)
    IntercomHistoricalBackfill.perform!(run:, client: @client, batch_size: 1, scanner: CleanScanner.new)
    assert_equal 1, run.reload.cursor_position
    original_adapter = IntercomBackfillJob.queue_adapter
    IntercomBackfillJob.queue_adapter = FailingQueueAdapter.new

    IntercomBackfillJob.enqueue_after_commit(run)

    assert run.reload.failed?
    assert_equal "enqueue_error", run.failure_code
    assert_equal 1, run.cursor_position
    IntercomBackfillJob.queue_adapter = original_adapter
    IntercomHistoricalBackfill.resume!(run:, membership: @owner, client: @client, enqueue: false)
    IntercomHistoricalBackfill.perform!(run: run.reload, client: @client, batch_size: 1, scanner: CleanScanner.new)
    assert run.reload.completed?
    assert_equal 2, run.intercom_backfill_report.counts.fetch("imported")
    assert_equal 2, @connection.intercom_conversation_links.count
    assert @client.assert_get_only!
  ensure
    IntercomBackfillJob.queue_adapter = original_adapter if original_adapter
  end

  private
    def customer_counts
      [ Contact.count, SourceIdentity.count, Conversation.count, ConversationMessage.count,
        IntercomConversationLink.count, IntercomPartLink.count, StoredAttachment.count ]
    end

    def create_identity(contact, source_id, email)
      identity = @workspace.source_identities.create!(
        entity_kind: :contact, source_namespace: "manual_import", source_record_type: :contact,
        source_record_id: source_id, status: :matched, contact:, resolution_method: :created, resolved_at: Time.current
      )
      identity.source_identity_keys.create!(workspace: @workspace, kind: :email, normalized_value: email)
    end

    def remote_conversation
      {
        "type" => "conversation", "id" => "conversation_history", "created_at" => 90,
        "updated_at" => 100, "state" => "closed", "title" => "Historical request",
        "contacts" => { "contacts" => [
          { "type" => "contact", "id" => "contact_history", "email" => "history@example.net", "name" => "History" }
        ] },
        "source" => {
          "id" => "source_history", "part_type" => "contact_reply", "created_at" => 90,
          "body" => "Original request", "author" => { "type" => "contact", "name" => "History" }
        },
        "conversation_parts" => { "conversation_parts" => [
          {
            "id" => "note_history", "part_type" => "note", "created_at" => 96, "body" => "Private note",
            "author" => { "type" => "admin", "name" => "Teammate" },
            "attachments" => [ { "id" => "file_history", "name" => "history.txt", "url" => "https://files.intercom.test/history.txt" } ]
          },
          {
            "id" => "reply_history", "part_type" => "comment", "created_at" => 98, "body" => "Historical reply",
            "author" => { "type" => "admin", "name" => "Teammate" }
          }
        ] },
        "tags" => { "tags" => [] }
      }
    end

    def install_attachment_link_failure
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE FUNCTION test_reject_intercom_attachment_link() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'injected attachment link failure'; END;
        $$;
        CREATE TRIGGER test_reject_intercom_attachment_link
          BEFORE INSERT ON intercom_part_attachments
          FOR EACH ROW EXECUTE FUNCTION test_reject_intercom_attachment_link();
      SQL
    end

    def remove_attachment_link_failure
      connection = ActiveRecord::Base.connection
      connection.execute("DROP TRIGGER IF EXISTS test_reject_intercom_attachment_link ON intercom_part_attachments")
      connection.execute("DROP FUNCTION IF EXISTS test_reject_intercom_attachment_link()")
    end

    def attachment_storage_objects
      Dir.glob(File.join(ActiveStorage::Blob.service.root, "**", "*"))
        .select { |path| File.file?(path) }.sort
    end
end
