require "test_helper"

class CorpusIntakeTest < ActiveSupport::TestCase
  setup do
    @corpus = workspaces(:acme_support).corpora.create!(name: "Unseen export")
    @membership = memberships(:owner_support)
    @records = [ { id: "sso-a", title: "Certificate expiry", content: "Ask admin@example.org for metadata", context: { plan: "enterprise", contacts: [ "security@example.org" ] } },
      { id: "api-b", title: "Duplicate webhook", content: "A replay writes two invoices", context: {} } ]
  end

  test "immutable provenance redaction and repeat/change semantics" do
    first = import(@records.to_json)
    assert_equal Digest::SHA256.hexdigest(@records.to_json), first.digest
    assert_equal 2, first.corpus_items.count
    record = first.corpus_items.find_by!(external_id: "sso-a")
    assert_equal "Ask [email redacted] for metadata", record.content
    assert_equal [ "[email redacted]" ], record.context["contacts"]
    assert_equal first.id, import(@records.to_json).id
    changed = @records.map(&:dup)
    changed.first[:content] = "Ask for the certificate expiry date first"
    second = import(changed.to_json)
    assert_equal 2, second.number
    assert_equal [ second.id ], @corpus.current_items.distinct.pluck(:source_snapshot_id)
    assert_equal "Ask [email redacted] for metadata", record.reload.content
    assert_equal first.id, import(@records.to_json).id
    assert_equal 2, SourceSnapshot.count
    assert_raises(ActiveRecord::ReadOnlyRecord) { record.update!(content: "rewritten") }
    assert_raises(ActiveRecord::StatementInvalid) do
      CorpusItem.transaction(requires_new: true) { CorpusItem.where(id: record.id).update_all(content: "rewritten") }
    end
  end

  test "redaction is a versioned choice and email IDs do not collide" do
    records = @records.map(&:dup)
    records[0][:id] = "admin@example.org"
    records[1][:id] = "admin@other.org"
    first = import(records.to_json)
    assert_equal 2, first.corpus_items.pluck(:external_id).uniq.size
    assert first.corpus_items.pluck(:external_id).none? { |id| id.include?("@") }
    original = import(records.to_json, redaction: "none")
    assert_equal 2, original.number
    assert_includes original.corpus_items.pluck(:content), "Ask admin@example.org for metadata"
  end

  test "expert chosen exact text masks literal case sensitive values without keeping the values" do
    records = [ { id: "Alice-tenant", title: "Alice SSO", content: "Alice: +1 555 0100; .*! stays literal; alice stays distinct.",
      context: { "Alice" => [ "+1 555 0100", { "unchanged" => false, "absent" => nil } ] } } ]
    snapshot = import(records.to_json, redaction: "exact", redaction_values: "Alice\r\n+1 555 0100\n.*!\n")
    item = snapshot.corpus_items.sole
    assert_equal "record-#{Digest::SHA256.hexdigest('Alice-tenant')}", item.external_id
    assert_equal "[text redacted] SSO", item.title
    assert_equal "[text redacted]: [text redacted]; [text redacted] stays literal; alice stays distinct.", item.content
    assert_equal({ "[text redacted]" => [ "[text redacted]", { "unchanged" => false, "absent" => nil } ] }, item.context)
    assert_equal 3, snapshot.mask_count
    assert_equal Digest::SHA256.hexdigest('["+1 555 0100",".*!","Alice"]'), snapshot.mask_digest
    assert_not_includes snapshot.attributes.to_json, "Alice"
    assert_not_includes snapshot.attributes.to_json, "+1 555 0100"
    assert_equal snapshot.id, import(records.to_json, redaction: "exact", redaction_values: ".*!\nAlice\n+1 555 0100\nAlice").id
  end

  test "exact matches use longest values at the same position and preserve Unicode and rule boundaries" do
    records = [ { id: "literal", title: "Fixture", content: "tenant-ABC / tenant-A / café / CAFE / padded ", context: {} } ]
    snapshot = import(records.to_json, redaction: "exact", redaction_values: "tenant-A\ntenant-ABC\ncafé\n padded ")
    assert_equal "[text redacted] / [text redacted] / [text redacted] / CAFE /[text redacted]", snapshot.corpus_items.sole.content
    maximum = 50.times.map { |i| "value-#{i}" }
    maximum[0] = "雪" * 200
    assert_equal 50, import(records.to_json, redaction: "exact", redaction_values: maximum.join("\n")).mask_count
    assert_equal 1, import(records.to_json, redaction: "exact", redaction_values: "abc").mask_count
    boundary = 40.times.map { |i| "#{i.to_s.rjust(3, '0')}#{'x' * 197}" }.push("q" * 152).join("\n")
    assert_equal 8192, boundary.bytesize
    assert_equal 41, import(records.to_json, redaction: "exact", redaction_values: boundary).mask_count
  end

  test "changed exact text choices create immutable snapshots with distinct database identity" do
    first = import(@records.to_json, redaction: "exact", redaction_values: "metadata")
    second = import(@records.to_json, redaction: "exact", redaction_values: "invoices")
    assert_equal first.digest, second.digest
    assert_equal first.processing_version, second.processing_version
    assert_not_equal first.mask_digest, second.mask_digest
    assert_equal 2, second.number
    assert_equal "Ask admin@example.org for [text redacted]", first.corpus_items.first.content
    assert_equal "Ask admin@example.org for metadata", second.corpus_items.first.content
    assert_equal first.id, import(@records.to_json, redaction: "exact", redaction_values: "metadata").id
    assert_raises(ActiveRecord::ReadOnlyRecord) { first.update!(mask_count: 2) }
    assert_raises(ActiveRecord::StatementInvalid) do
      SourceSnapshot.transaction(requires_new: true) { SourceSnapshot.where(id: first.id).update_all(mask_digest: second.mask_digest) }
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      SourceSnapshot.transaction(requires_new: true) do
        first.source.source_snapshots.create!(first.attributes.except("id").merge("number" => 3))
      end
    end
    [ { "mask_count" => 51 }, { "redaction" => "none" } ].each do |invalid|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        SourceSnapshot.transaction(requires_new: true) do
          SourceSnapshot.insert_all!([ first.attributes.except("id").merge("number" => 3).merge(invalid) ])
        end
      end
      assert_kind_of PG::CheckViolation, error.cause
    end
  end

  test "exact text errors refuse collisions and malformed rules without changes or private error values" do
    snapshot = import(@records.to_json)
    source_state = snapshot.source.reload.attributes
    collision = [ { id: "one", title: "Fixture", content: "Separate facts", context: { "secret-first" => false, "secret-second" => nil } } ]
    options = [ { redaction: "exact", redaction_values: "secret-first\nsecret-second", bytes: collision.to_json },
      { redaction: "exact", redaction_values: "" }, { redaction: "exact", redaction_values: [ "secret-first" ] },
      { redaction: "exact", redaction_values: "secret-first\0" }, { redaction: "exact", redaction_values: "\xff".b },
      { redaction: "exact", redaction_values: 51.times.map { |i| "secret-#{i}" }.join("\n") },
      { redaction: "exact", redaction_values: "x" * 201 }, { redaction: "exact", redaction_values: " " },
      { redaction: "exact", redaction_values: "ab" },
      { redaction: "exact", redaction_values: "x" * 8193 }, { redaction: "email", redaction_values: "secret-first" },
      { redaction: "none", redaction_values: "secret-first" } ]
    options.each do |option|
      bytes = option.delete(:bytes) || @records.to_json
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
        error = assert_raises(CorpusIntake::Invalid) { import(bytes, **option, retention_days: 2) }
        assert_not_includes error.message, "secret-first"
        assert_not_includes error.message, "secret-second"
      end
      assert_equal source_state, snapshot.source.reload.attributes
    end
  end

  test "recursive masking collisions refuse the whole batch without rewriting retained history" do
    original = import(@records.to_json)
    items_state = original.corpus_items.order(:id).map(&:attributes)
    collisions = [ { "first@example.org" => "First report", "second@example.org" => "Different report" },
      { "[email redacted]" => false, "third@example.org" => nil },
      { "nested" => [ { "owner@example.org" => { "plan" => "enterprise" }, "other@example.org" => { "plan" => "pro" } } ] } ]
    collisions.each do |context|
      source_state = original.source.reload.attributes
      records = @records.deep_dup
      records.last[:context] = context
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
        error = assert_raises(CorpusIntake::Invalid) { import(records.to_json, retention_days: 2) }
        assert_equal "Email masking would merge distinct JSON keys. Rename those keys before upload; no records were imported.", error.message
        assert_not_includes error.message, "@"
      end
      assert_equal source_state, original.source.reload.attributes
      assert_equal items_state, original.corpus_items.order(:id).map(&:attributes)
      assert_equal context.deep_stringify_keys, import(records.to_json, redaction: "none").corpus_items.find_by!(external_id: "api-b").context
      original.source.update!(current_snapshot: original, expires_at: source_state.fetch("expires_at"))
    end
  end

  test "previously retained colliding input cannot bypass validation through snapshot reuse" do
    records = @records.deep_dup
    records.last[:context] = { "first@example.org" => "First report", "second@example.org" => "Different report" }
    source = @corpus.sources.create!(workspace: @corpus.workspace, name: "History", kind: "conversations", expires_at: 30.days.from_now)
    old = source.source_snapshots.create!(workspace: @corpus.workspace, corpus: @corpus, imported_by: @membership.user,
      number: 1, digest: Digest::SHA256.hexdigest(records.to_json), redaction: "email", processing_version: CorpusIntake::PROCESSING_VERSION, created_at: Time.current)
    old.corpus_items.create!(workspace: @corpus.workspace, corpus: @corpus, external_id: "api-b", title: "Historical masked output",
      content: "Retained history is not repaired automatically.", context: { "[email redacted]" => "Different report" }, created_at: Time.current)
    source.update!(current_snapshot: old)
    source_state = source.reload.attributes
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      assert_raises(CorpusIntake::Invalid) { import(records.to_json) }
    end
    assert_equal source_state, source.reload.attributes
    assert_equal({ "[email redacted]" => "Different report" }, old.corpus_items.sole.context)
  end

  test "masked record IDs cannot collide with existing digest-shaped input IDs" do
    records = @records.deep_dup
    records.first[:id] = "first@example.org"
    records.last[:id] = "record-#{Digest::SHA256.hexdigest(records.first[:id])}"
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      error = assert_raises(CorpusIntake::Invalid) { import(records.to_json) }
      assert_equal "Masking would merge distinct record IDs. Rename those IDs before upload; no records were imported.", error.message
    end
    assert_equal records.map { |record| record[:id] }, import(records.to_json, redaction: "none").corpus_items.order(:id).pluck(:external_id)
  end

  test "processing version forms part of immutable snapshot reuse and database identity" do
    source = @corpus.sources.create!(workspace: @corpus.workspace, name: "History", kind: "conversations", expires_at: 30.days.from_now)
    old = source.source_snapshots.create!(workspace: @corpus.workspace, corpus: @corpus, imported_by: @membership.user,
      number: 1, digest: Digest::SHA256.hexdigest(@records.to_json), redaction: "email", processing_version: "prior-synthetic-intake", created_at: Time.current)
    old.corpus_items.create!(workspace: @corpus.workspace, corpus: @corpus, external_id: "sso-a", title: "Old parser output", content: "Fixed historical output", created_at: Time.current)
    source.update!(current_snapshot: old)
    old_state = old.reload.attributes
    newer = import(@records.to_json)
    assert_not_equal old.id, newer.id
    assert_equal 2, newer.number
    assert_equal CorpusIntake::PROCESSING_VERSION, newer.processing_version
    assert_equal old.digest, newer.digest
    assert_equal 2, newer.corpus_items.count
    assert_equal old_state, old.reload.attributes
    assert_equal "Fixed historical output", old.corpus_items.sole.content
    assert_equal newer.id, import(@records.to_json).id
    assert_equal newer.id, source.reload.current_snapshot_id
    assert_equal 2, source.source_snapshots.count
    assert_raises(ActiveRecord::RecordNotUnique) do
      SourceSnapshot.transaction(requires_new: true) do
        source.source_snapshots.create!(newer.attributes.except("id").merge("number" => 3))
      end
    end
  end

  test "supported vendor shapes retain all messages without executing HTML" do
    zendesk = import({ tickets: [ { id: 91, subject: "Reopened", description: "Still broken", comments: [ { body: "Escalate to Engineering" } ] } ] }.to_json)
    assert_equal "Still broken\n\nEscalate to Engineering", zendesk.corpus_items.sole.content
    intercom = import({ conversations: [ { id: "c17", title: "SSO", source: { body: "<script>bad()</script>" }, conversation_parts: { conversation_parts: [ { body: "Need logs" } ] } } ] }.to_json)
    assert_equal "<script>bad()</script>\n\nNeed logs", intercom.corpus_items.sole.content
  end

  test "malformed shapes sizes IDs and partial bad batches leave no records" do
    invalid = [ "[]", "null", '[{"id":null,"title":"a","content":"b"}]', '[{"id":"a","title":"a","content":"\\u0000"}]',
      { tickets: [ { id: 1, subject: "a", comments: {} } ] }.to_json,
      { conversations: [ { id: 1, source: nil } ] }.to_json,
      [ @records.first, @records.first ].to_json,
      [ @records.first, { id: "bad", title: "bad", content: "" } ].to_json,
      ("x" * (CorpusIntake::MAX_BYTES + 1)), "\xff".b ]
    invalid.each do |bytes|
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
        assert_raises(CorpusIntake::Invalid, ActiveRecord::RecordInvalid) { import(bytes) }
      end
    end
  end

  test "foreign membership and foreign snapshot relationships fail" do
    assert_raises(Current::RoleAccessDenied) { import(@records.to_json, membership: memberships(:outsider_beta)) }
    first = import(@records.to_json)
    other = workspaces(:beta_support).corpora.create!(name: "Other")
    assert_raises(ActiveRecord::InvalidForeignKey) do
      CorpusItem.transaction(requires_new: true) do
        CorpusItem.create!(workspace: other.workspace, corpus: other, source_snapshot: first,
          external_id: "foreign", title: "Other", content: "No")
      end
    end
    viewer = Membership.create!(workspace: @corpus.workspace, user: users(:teammate), role: :viewer)
    assert_raises(Current::RoleAccessDenied) { import(@records.to_json, membership: viewer) }
  end

  test "retention removes source content but keeps a non-content audit" do
    snapshot = import(@records.to_json, retention_days: 1)
    travel 2.days do
      assert_empty @corpus.current_items
      SourceRetentionJob.perform_now
      assert_not Source.exists?(snapshot.source_id)
      assert_empty @corpus.corpus_items
      assert_empty @corpus.source_snapshots
      event = @corpus.workspace.audit_events.find_by!(action: "source.deleted")
      assert_equal({}, event.metadata)
      assert_equal "system", event.actor_kind
    end
  end

  private
    def import(bytes, **options)
      CorpusIntake.call(corpus: @corpus, membership: @membership, name: "History", kind: "conversations", bytes:, **options)
    end
end
