require "test_helper"

class MemoryRecordTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @agent = @workspace.agent_profiles.first
  end

  test "preserves conflicting corrections and ranks authority without overwriting source records" do
    inferred = create_memory(authority: "inference", origin_kind: "agent", source_agent_profile: @agent,
      content: "Customer prefers weekly reports", confidence: 0.8)
    source = create_memory(authority: "source_record", content: "Customer prefers monthly reports", confidence: 1)
    first_correction = create_human_correction(source, "Customer prefers quarterly reports")
    second_correction = create_human_correction(source, "Customer has no fixed report schedule")

    assert_equal 4, @workspace.memory_records.count
    assert_equal [ inferred.id, first_correction.id, second_correction.id ].sort,
      @workspace.memory_records.current.where(topic: source.topic).pluck(:id).sort
    ranked = @workspace.memory_records.where(topic: source.topic).prioritized.pluck(:id)
    assert_equal [ first_correction.id, second_correction.id ].sort, ranked.first(2).sort
    assert_equal [ source.id, inferred.id ], ranked.last(2)
    assert_equal "Customer prefers monthly reports", source.reload.content
  end

  test "database rejects supersession across scopes even when validations are bypassed" do
    source = create_memory(authority: "source_record")
    other_account = accounts(:acme_duplicate)

    error = assert_raises(ActiveRecord::StatementInvalid) do
      MemoryRecord.transaction(requires_new: true) do
        MemoryRecord.insert_all!([ insert_attributes(
          account_id: other_account.id,
          supersedes_memory_record_id: source.id,
          memory_key: SecureRandom.uuid
        ) ])
      end
    end

    assert_match(/superseding memory must keep/, error.message)
    assert_equal 1, @workspace.memory_records.count
  end

  test "lower authority cannot supersede a correction" do
    source = create_memory(authority: "source_record")
    correction = create_human_correction(source, "Corrected preference")
    replacement = MemoryRecord.new(attributes_for_memory(
      authority: "inference", origin_kind: "agent", source_agent_profile: @agent,
      supersedes_memory_record: correction
    ))

    assert_not replacement.valid?
    assert_includes replacement.errors[:authority], "cannot rank below the superseded memory"
    assert_database_rejects(
      authority: "inference", origin_kind: "agent", source_agent_profile_id: @agent.id,
      supersedes_memory_record_id: correction.id
    )
  end

  test "a correction requires a manager and procedural memory requires human authority" do
    viewer = Membership.create!(workspace: @workspace, user: users(:teammate), role: :viewer)
    correction = MemoryRecord.new(attributes_for_memory(
      authority: "human_correction", origin_kind: "human", source_membership: viewer, source_user: viewer.user
    ))
    procedure = MemoryRecord.new(attributes_for_memory(memory_type: "procedural"))

    assert_not correction.valid?
    assert_includes correction.errors[:source_membership], "must be an authorized workspace member"
    assert_not procedure.valid?
    assert_includes procedure.errors[:authority], "must be an authorized human assertion"
    assert_database_rejects(
      authority: "human_correction", origin_kind: "human", source_membership_id: viewer.id,
      source_user_id: viewer.user_id
    )
  end

  test "valid and retention times bound eligibility" do
    now = Time.current
    active = create_memory(authority: "source_record", valid_from: now - 1.hour)
    future = create_memory(authority: "source_record", valid_from: now + 1.hour)
    ended = create_memory(authority: "source_record", valid_from: now - 2.hours, valid_until: now - 1.hour)
    expired = create_memory(
      authority: "source_record", observed_at: now - 2.hours, valid_from: now - 2.hours,
      retention_policy: "time_bound", retention_until: now - 1.hour
    )

    assert_equal [ active.id ], @workspace.memory_records.eligible_at(now).pluck(:id)
    assert_not_includes @workspace.memory_records.eligible_at(now), future
    assert_not_includes @workspace.memory_records.eligible_at(now), ended
    assert_not_includes @workspace.memory_records.eligible_at(now), expired
  end

  test "database rejects cross-workspace scope targets and malformed time or confidence" do
    assert_database_rejects(account_id: accounts(:beta).id)
    assert_database_rejects(confidence: 1.1)
    assert_database_rejects(valid_until: 1.hour.ago)
  end

  test "records are append only" do
    memory = create_memory(authority: "source_record")

    assert memory.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { memory.update!(content: "Changed") }
    assert_raises(ActiveRecord::StatementInvalid) do
      MemoryRecord.where(id: memory.id).update_all(content: "Changed")
    end
  end

  private
    def create_memory(overrides = {})
      MemoryRecord.create!(attributes_for_memory(**overrides))
    end

    def create_human_correction(source, content)
      membership = memberships(:owner_support)
      create_memory(
        authority: "human_correction", origin_kind: "human", source_membership: membership,
        source_user: membership.user, content: content, supersedes_memory_record: source
      )
    end

    def attributes_for_memory(**overrides)
      now = Time.current
      {
        workspace: @workspace,
        memory_type: "profile",
        scope_kind: "account",
        account_id: accounts(:acme).id,
        topic: "reporting-preference",
        content: "Customer prefers monthly reports",
        authority: "source_record",
        origin_kind: "system",
        source_reference: "conversation-message://123",
        source_digest: Digest::SHA256.hexdigest("source"),
        observed_at: now,
        valid_from: now,
        confidence: 1,
        retention_policy: "indefinite",
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def insert_attributes(**overrides)
      record = MemoryRecord.new(attributes_for_memory(**overrides))
      record.valid?
      record.attributes.except("id")
    end

    def assert_database_rejects(**overrides)
      assert_raises(ActiveRecord::StatementInvalid) do
        MemoryRecord.transaction(requires_new: true) do
          MemoryRecord.insert_all!([ insert_attributes(**overrides, memory_key: SecureRandom.uuid) ])
        end
      end
    end
end
