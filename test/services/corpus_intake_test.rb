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
