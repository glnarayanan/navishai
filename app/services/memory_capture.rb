class MemoryCapture
  class Conflict < StandardError; end

  MAX_CONTENT_BYTES = 32_768

  def self.message!(workspace:, message:)
    message = workspace.conversation_messages.find(message.id)
    support_case = workspace.support_cases.find_by!(conversation_id: message.conversation_id)
    direction = message.inbound? ? "Customer" : "Human support"
    content = bounded("#{direction} message: #{message.body}")
    capture!(
      workspace:, capture_key: "conversation-message:#{message.id}", memory_type: :episodic,
      scope_kind: :support_case, scope_target: support_case, topic: "conversation-message",
      content:, source_reference: "conversation-message://#{message.id}",
      source_digest: Digest::SHA256.hexdigest(message.body.b), observed_at: message.occurred_at
    )
  end

  def self.case_outcome!(workspace:, change:)
    change = workspace.support_case_status_changes.find(change.id)
    return unless change.to_status.in?(%w[resolved closed])

    support_case = workspace.support_cases.find(change.support_case_id)
    source = JSON.generate(
      case_id: support_case.id, from: change.from_status, to: change.to_status,
      reason: change.reason, occurred_at: change.occurred_at.iso8601(6)
    )
    capture!(
      workspace:, capture_key: "case-outcome:#{change.id}", memory_type: :episodic,
      scope_kind: :support_case, scope_target: support_case, topic: "case-outcome",
      content: bounded("Case #{change.to_status}: #{change.reason}"),
      source_reference: "case-status-change://#{change.id}",
      source_digest: Digest::SHA256.hexdigest(source), observed_at: change.occurred_at
    )
  end

  def self.capture!(workspace:, capture_key:, memory_type:, scope_kind:, scope_target:, topic:, content:,
    source_reference:, source_digest:, observed_at:, authority: :source_record, origin_kind: :system,
    source_agent_profile: nil, source_membership: nil, source_user: nil, confidence: 1)
    MemoryRecord.transaction do
      lock_capture!(workspace, capture_key)
      attributes = scope_attributes(scope_kind, scope_target).merge(
        memory_type: memory_type.to_s, topic:, content:, authority: authority.to_s, origin_kind: origin_kind.to_s,
        source_reference:, source_digest:, observed_at:, valid_from: observed_at, confidence:,
        retention_policy: "source_lifetime", source_agent_profile:, source_membership:, source_user:
      )
      existing = workspace.memory_records.find_by(capture_key: capture_key)
      if existing
        verify_contract!(existing, attributes)
        return existing
      end

      record = workspace.memory_records.create!(**attributes, capture_key:)
      entry = workspace.memory_index_entries.create!(memory_record: record)
      AuditEvent.record!(
        action: "memory.record_captured", source: :system, workspace:, actor_kind: :system,
        subject: record, metadata: { memory_type: record.memory_type }
      )
      MemoryIndexJob.enqueue_after_commit(entry)
      record
    end
  end

  def self.scope_attributes(scope_kind, target)
    kind = scope_kind.to_s
    raise ArgumentError, "memory scope is unsupported" unless kind.in?(MemoryRecord::SCOPE_KINDS)
    raise ArgumentError, "memory scope target is required" unless target

    association = kind == "crew" ? :crew_template : kind.to_sym
    { scope_kind: kind, association => target }
  end

  def self.lock_capture!(workspace, capture_key)
    value = MemoryRecord.connection.quote("memory-capture:#{workspace.id}:#{capture_key}")
    MemoryRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{value}))")
  end
  private_class_method :lock_capture!

  def self.verify_contract!(record, attributes)
    stable_attributes = attributes.except(:observed_at, :valid_from)
    expected = stable_attributes.transform_values { |value| value.is_a?(ApplicationRecord) ? value.id : value }
    actual = expected.keys.index_with do |key|
      value = record.public_send(key)
      value.is_a?(ApplicationRecord) ? value.id : value
    end
    raise Conflict, "capture key was already used for different memory" unless actual == expected
  end
  private_class_method :verify_contract!

  def self.bounded(value)
    value.to_s.truncate_bytes(MAX_CONTENT_BYTES, omission: "")
  end
  private_class_method :bounded
end
