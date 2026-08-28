class MemoryPortability
  class InvalidArchive < StandardError; end

  FORMAT = "navishai-memory-v1"
  MAX_BYTES = 20.megabytes
  RECORD_ATTRIBUTES = %w[
    memory_key memory_type scope_kind organization_id account_id contact_id support_case_id crew_template_id
    agent_profile_id user_id topic content content_digest authority origin_kind source_reference source_digest
    observed_at valid_from valid_until confidence retention_policy retention_until source_agent_profile_id
    source_membership_id source_user_id capture_key supersedes_memory_key
  ].freeze

  def self.export(workspace:, membership:)
    actor = manager!(workspace, membership)
    MemoryRecord.transaction(isolation: :repeatable_read) do
      records = workspace.memory_records.includes(:supersedes_memory_record).order(:id).map do |record|
        record.attributes.slice(*RECORD_ATTRIBUTES).merge(
          "supersedes_memory_key" => record.supersedes_memory_record&.memory_key
        )
      end
      archive = {
        "format" => FORMAT,
        "workspace_key" => workspace.runner_key,
        "exported_at" => Time.current.iso8601(6),
        "memory_records" => records,
        "memory_proposals" => portable_rows(workspace.memory_proposals),
        "correction_proposals" => portable_rows(workspace.memory_correction_proposals),
        "tombstones" => portable_rows(workspace.memory_tombstones)
      }
      AuditEvent.record!(
        action: "memory.exported", source: :web, workspace:, actor: actor.user,
        subject: workspace, metadata: { record_count: records.size }
      )
      JSON.generate(archive)
    end
  end

  def self.import!(workspace:, membership:, json:)
    actor = manager!(workspace, membership)
    raise InvalidArchive, "memory archive is too large" if json.to_s.bytesize > MAX_BYTES
    archive = JSON.parse(json)
    validate_archive!(archive, workspace)

    MemoryRecord.transaction do
      workspace = Workspace.lock.find(workspace.id)
      actor = manager!(workspace, membership, lock: true)
      raise InvalidArchive, "workspace is no longer active" if workspace.deletion_requested?
      raise InvalidArchive, "workspace memory must be empty before import" if workspace.memory_records.exists?

      records = import_records!(workspace, archive.fetch("memory_records"))
      import_rows!(workspace.memory_proposals, archive.fetch("memory_proposals"), records)
      import_rows!(workspace.memory_correction_proposals, archive.fetch("correction_proposals"), records)
      import_rows!(workspace.memory_tombstones, archive.fetch("tombstones"), records)
      records.each_value do |record|
        next if record.memory_tombstone || record.revisions.exists?

        MemoryIndexJob.enqueue_after_commit(workspace.memory_index_entries.create!(memory_record: record))
      end
      AuditEvent.record!(
        action: "memory.imported", source: :web, workspace:, actor: actor.user,
        subject: workspace, metadata: { record_count: records.size }
      )
      records.size
    end
  rescue JSON::ParserError, KeyError, TypeError, ActiveRecord::RecordInvalid => error
    raise InvalidArchive, "memory archive is invalid: #{error.message}"
  end

  def self.reconstruct_index!(workspace:, membership:, include_pending: false)
    actor = manager!(workspace, membership)
    count = 0
    requested_at = Time.current
    MemoryIndexEntry.transaction do
      workspace.memory_records.current.available.find_each do |record|
        entry = workspace.memory_index_entries.find_or_initialize_by(memory_record: record)
        missing_entry = entry.new_record?
        entry.save! if missing_entry
        stale_claim = entry.indexing? && entry.last_attempted_at && entry.last_attempted_at < requested_at - 5.minutes
        next unless missing_entry || (include_pending && entry.pending?) || entry.failed? || entry.unknown? || stale_claim

        entry.update!(
          status: :indexing, attempt_count: entry.attempt_count + 1,
          failure_code: nil, external_document_id: nil,
          external_status: nil, indexed_at: nil, last_attempted_at: requested_at
        )
        MemoryIndexJob.enqueue_after_commit(entry, force: true)
        count += 1
      end
      AuditEvent.record!(
        action: "memory.index_reconstructed", source: :web, workspace:, actor: actor.user,
        subject: workspace, metadata: { queued_count: count }
      )
    end
    count
  end

  def self.portable_rows(relation)
    associations = %i[memory_record published_memory_record].select do |name|
      relation.klass.reflect_on_association(name)
    end
    relation.includes(*associations).order(:id).map do |row|
      attributes = row.attributes.except(
        "id", "workspace_id", "created_at", "updated_at", "memory_record_id", "published_memory_record_id"
      )
      attributes["memory_record_key"] = row.memory_record.memory_key if row.respond_to?(:memory_record)
      if row.respond_to?(:published_memory_record) && row.published_memory_record
        attributes["published_memory_record_key"] = row.published_memory_record.memory_key
      end
      attributes
    end
  end
  private_class_method :portable_rows

  def self.validate_archive!(archive, workspace)
    raise InvalidArchive, "memory archive format is unsupported" unless archive["format"] == FORMAT
    raise InvalidArchive, "memory archive belongs to another workspace" unless archive["workspace_key"] == workspace.runner_key
    %w[memory_records memory_proposals correction_proposals tombstones].each do |key|
      raise InvalidArchive, "memory archive #{key} is invalid" unless archive[key].is_a?(Array)
    end
  end
  private_class_method :validate_archive!

  def self.import_records!(workspace, rows)
    pending = rows.map(&:deep_dup)
    records = {}
    until pending.empty?
      ready, pending = pending.partition { |row| row["supersedes_memory_key"].blank? || records.key?(row["supersedes_memory_key"]) }
      raise InvalidArchive, "memory supersession chain is invalid" if ready.empty?

      ready.each do |row|
        prior = records[row.delete("supersedes_memory_key")]
        record = workspace.memory_records.create!(**row.slice(*RECORD_ATTRIBUTES), supersedes_memory_record: prior)
        records[record.memory_key] = record
      end
    end
    records
  end
  private_class_method :import_records!

  def self.import_rows!(relation, rows, records)
    rows.each do |row|
      attributes = row.deep_dup
      { "memory_record_key" => "memory_record_id", "published_memory_record_key" => "published_memory_record_id" }.each do |key, column|
        next unless attributes[key]

        source = records[attributes.delete(key)]
        raise InvalidArchive, "memory archive reference is invalid" unless source
        attributes[column] = source.id
      end
      relation.create!(attributes)
    end
  end
  private_class_method :import_rows!

  def self.manager!(workspace, membership, lock: false)
    memberships = workspace.memberships
    memberships = memberships.lock if lock
    memberships.find(membership.id).tap do |current|
      raise Current::RoleAccessDenied unless current.can_manage_work?
    end
  end
  private_class_method :manager!
end
