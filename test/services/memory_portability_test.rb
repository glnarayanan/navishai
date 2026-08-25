require "test_helper"

class MemoryPortabilityTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
  end

  test "exports a bounded workspace archive with user audit and no external index state" do
    memory = create_memory(@workspace, "Portable preference")
    @workspace.memory_index_entries.create!(
      memory_record: memory, status: :indexed, attempt_count: 1,
      external_document_id: "engine-private-id", external_status: "done",
      last_attempted_at: Time.current, indexed_at: Time.current
    )

    json = MemoryPortability.export(workspace: @workspace, membership: @owner)
    archive = JSON.parse(json)
    assert_equal MemoryPortability::FORMAT, archive.fetch("format")
    exported = archive.fetch("memory_records").find { |row| row.fetch("memory_key") == memory.memory_key }
    assert_equal "Portable preference", exported.fetch("content")
    assert_not_includes json, "engine-private-id"
    audit = @workspace.audit_events.find_by!(action: "memory.exported")
    assert_equal @owner.user, audit.actor
  end

  test "imports into an empty workspace and reconstructs index entries without an engine dependency" do
    destination = workspaces(:beta_support)
    owner = destination.memberships.create!(user: User.create!(
      email_address: "memory-import@example.com", password: "password12345", verified_at: Time.current
    ), role: :owner)
    archive = {
      format: MemoryPortability::FORMAT, workspace_key: destination.runner_key,
      exported_at: Time.current.iso8601,
      memory_records: [ portable_record(owner) ], memory_proposals: [],
      correction_proposals: [], tombstones: []
    }

    assert_difference -> { destination.memory_records.count }, 1 do
      assert_equal 1, MemoryPortability.import!(
        workspace: destination, membership: owner, json: JSON.generate(archive)
      )
    end
    record = destination.memory_records.sole
    assert_equal "Imported policy", record.content
    assert_equal record, destination.memory_index_entries.sole.memory_record
    assert destination.audit_events.exists?(action: "memory.imported", actor: owner.user)

    destination.memory_index_entries.sole.update!(
      status: :indexing, attempt_count: 1, last_attempted_at: Time.current
    )
    destination.memory_index_entries.sole.update!(status: :failed, failure_code: "offline")
    assert_equal 1, MemoryPortability.reconstruct_index!(workspace: destination, membership: owner)
  end

  test "rejects cross-workspace archives and non-manager operations" do
    archive = JSON.generate(
      format: MemoryPortability::FORMAT, workspace_key: SecureRandom.uuid,
      memory_records: [], memory_proposals: [], correction_proposals: [], tombstones: []
    )
    assert_raises(MemoryPortability::InvalidArchive) do
      MemoryPortability.import!(workspace: @workspace, membership: @owner, json: archive)
    end
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "memory-export-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    assert_raises(Current::RoleAccessDenied) do
      MemoryPortability.export(workspace: @workspace, membership: member)
    end
  end

  private
    def create_memory(workspace, content)
      workspace.memory_records.create!(
        memory_type: :profile, scope_kind: :workspace, topic: "portable", content:,
        authority: :source_record, origin_kind: :system, source_reference: "test://portable",
        source_digest: Digest::SHA256.hexdigest(content), observed_at: 1.day.ago,
        valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
      )
    end

    def portable_record(owner)
      {
        memory_key: SecureRandom.uuid, memory_type: "procedural", scope_kind: "workspace",
        topic: "imported-policy", content: "Imported policy", authority: "human_correction",
        origin_kind: "human", source_reference: "archive://policy",
        source_digest: Digest::SHA256.hexdigest("Imported policy"), observed_at: 1.day.ago,
        valid_from: 1.day.ago, confidence: 1, retention_policy: "indefinite",
        source_membership_id: owner.id, source_user_id: owner.user_id
      }
    end
end
