require "test_helper"
require "stringio"
require "tempfile"

class StreamedCorpusIntakeTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:owner_support)
    @corpus = @membership.workspace.corpora.create!(name: "Streamed fixture only")
  end

  test "fixed large file uses bounded reads and inserts with complete immutable provenance" do
    Tempfile.create([ "navishai-fixture-", ".jsonl" ]) do |file|
      100_000.times do |index|
        file.puts(JSON.generate({ id: "row-#{index}", title: "雪 café #{index}",
          content: "Ask admin@example.org for metadata. " + "x" * 180,
          context: { nested: [ false, nil, index, "雪" ], reopened: index == 99_999 } }))
      end
      file.flush
      assert_operator file.size, :>, 10.megabytes
      assert_operator file.size, :<, 60.megabytes
      digest = Digest::SHA256.file(file.path).hexdigest
      file.define_singleton_method(:read) { |*| raise "Whole-file reads are forbidden" }
      read_arguments = Hash.new(0)
      bounded_gets = file.method(:gets)
      file.define_singleton_method(:gets) do |*arguments|
        read_arguments[arguments] += 1
        bounded_gets.call(*arguments)
      end
      batches = []
      observer = ->(event) do
        if event.payload[:sql].start_with?('INSERT INTO "corpus_items"')
          assert_equal [ "content" ], event.payload[:binds].map(&:name)
          batches << JSON.parse(event.payload[:binds].sole.value_for_database).size
        end
      end
      snapshot = nil
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { snapshot = import(file) }
      assert_equal({ [ "\n", 1.megabyte + 1 ] => 200_002 }, read_arguments)
      assert_equal [ 1000 ] * 100, batches
      assert_equal 100_000, snapshot.corpus_items.count
      assert_equal "conversations", snapshot.source.kind
      assert_equal "support-conversation-jsonl-v1", snapshot.processing_version
      assert_equal digest, snapshot.digest
      assert_equal @membership.user, snapshot.imported_by
      assert_equal snapshot.id, snapshot.source.current_snapshot_id
      [ 0, 99_999 ].each do |index|
        item = snapshot.corpus_items.find_by!(external_id: "row-#{index}")
        assert_equal "雪 café #{index}", item.title
        assert_equal "Ask [email redacted] for metadata. " + "x" * 180, item.content
        assert_equal({ "nested" => [ false, nil, index, "雪" ], "reopened" => index == 99_999 }, item.context)
        assert_equal @corpus.workspace_id, item.workspace_id
        assert_equal @corpus.id, item.corpus_id
        assert item.readonly?
      end
      assert_equal({ "record_count" => 100_000 }, @corpus.workspace.audit_events.where(action: "corpus.imported").last.metadata)
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count" ] do
        assert_equal snapshot.id, import(file).id
      end
      file.seek(0, IO::SEEK_END)
      file.puts(JSON.generate({ id: "extra", title: "Extra", content: "Not silently sampled" }))
      file.flush
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
        assert_raises(CorpusIntake::Invalid) { import(file) }
      end
      assert_equal snapshot.id, snapshot.source.reload.current_snapshot_id
    end
  end

  test "wire line and retained byte boundaries preserve UTF8 exact masks and raw digest" do
    bytes = JSON.generate({ id: "abc", title: "雪", content: "abc", context: { "abc" => [ false, nil, "abc" ] } }) + "\r\n"
    masked = { external_id: "record-#{Digest::SHA256.hexdigest('abc')}", title: "雪", content: "[text redacted]", context: { "[text redacted]" => [ false, nil, "[text redacted]" ] } }
    [ [ :STREAM_MAX_BYTES, bytes.bytesize ], [ :STREAM_MAX_LINE_BYTES, bytes.bytesize ],
      [ :STREAM_MAX_RETAINED_BYTES, JSON.generate(masked).bytesize ] ].each do |name, boundary|
      with_limit(name, boundary) do
        snapshot = import(StringIO.new(bytes), redaction: "exact", redaction_values: "abc")
        assert_equal Digest::SHA256.hexdigest(bytes), snapshot.digest
        assert_equal masked[:context], snapshot.corpus_items.sole.context
        assert_equal 1, snapshot.mask_count
      end
      with_limit(name, boundary - 1) do
        assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
          assert_raises(CorpusIntake::Invalid) { import(StringIO.new(bytes), redaction: "exact", redaction_values: "abc", retention_days: 2) }
        end
      end
    end
  end

  test "late invalid fields roll back prior batches and existing source retention" do
    original = import(StringIO.new(line("original")))
    state = original.source.reload.attributes
    records = 1001.times.map { |index| line("row-#{index}") }
    records[-1] = JSON.generate({ id: "last", title: "Late", content: "" }) + "\n"
    inserts = []
    observer = ->(event) { inserts << event.payload[:sql] if event.payload[:sql].start_with?('INSERT INTO "corpus_items"') }
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
        assert_raises(ActiveRecord::RecordInvalid) { import(StringIO.new(records.join), retention_days: 2) }
      end
    end
    assert_equal 1, inserts.size
    assert_equal state, original.source.reload.attributes
    assert_equal "original", original.corpus_items.sole.external_id
  end

  test "malformed duplicate and masking collisions refuse before reuse or mutation without echoing input" do
    original = import(StringIO.new(line("original")))
    state = original.source.reload.attributes
    invalid = [ "", "\n", "[]\n", "private-bad-json\n", line("duplicate") * 2,
      JSON.generate({ id: "private", title: "Fixture", content: "Body", context: { "a@example.org" => false, "b@example.org" => nil } }) + "\n",
      JSON.generate({ id: "private", title: "Fixture", content: "Body", context: [] }) + "\n",
      line("null").sub("Body", "bad\\u0000text"), line("utf8").b.sub("Body".b, "bad\xFF".b) ]
    invalid.each do |bytes|
      assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
        error = assert_raises(CorpusIntake::Invalid) { import(StringIO.new(bytes), retention_days: 2) }
        %w[private-bad-json a@example.org b@example.org].each { |private_text| assert_not_includes error.message, private_text }
      end
      assert_equal state, original.source.reload.attributes
    end
    viewer = @membership.workspace.memberships.create!(user: users(:teammate), role: :viewer)
    assert_raises(Current::RoleAccessDenied) { import(StringIO.new(line("viewer")), membership: viewer) }
    assert_raises(Current::RoleAccessDenied) { import(StringIO.new(line("foreign")), membership: memberships(:outsider_beta)) }
  end

  test "changed second-pass input rolls back and older processing identity never substitutes" do
    original = CorpusIntake.call(corpus: @corpus, membership: @membership, name: "Stream fixture", kind: "conversations", bytes: [ { id: "old", title: "Old", content: "Body" } ].to_json)
    io = StringIO.new(line("first"))
    rewinds = 0
    io.define_singleton_method(:rewind) do
      rewinds += 1
      self.string = '{"id":"second","title":"Second","content":"Changed"}' + "\n" if rewinds == 2
      super()
    end
    state = original.source.reload.attributes
    assert_no_difference [ "Source.count", "SourceSnapshot.count", "CorpusItem.count", "AuditEvent.count" ] do
      error = assert_raises(CorpusIntake::Invalid) { import(io) }
      assert_includes error.message, "changed"
    end
    assert_equal state, original.source.reload.attributes
    next_snapshot = import(StringIO.new(line("first")))
    assert_equal 2, next_snapshot.number
    assert_equal original.source_id, next_snapshot.source_id
    assert_equal "support-export-v1", original.reload.processing_version
    assert_equal "old", original.corpus_items.sole.external_id
  end

  private
    def line(id)
      JSON.generate({ id:, title: "Fixture", content: "Body" }) + "\n"
    end

    def import(file, **options)
      CorpusIntake.call(**{ corpus: @corpus, membership: @membership, name: "Stream fixture", kind: "conversation_lines", file: }.merge(options))
    end

    def with_limit(name, value)
      original = CorpusIntake.const_get(name)
      CorpusIntake.send(:remove_const, name)
      CorpusIntake.const_set(name, value)
      yield
    ensure
      CorpusIntake.send(:remove_const, name)
      CorpusIntake.const_set(name, original)
    end
end
