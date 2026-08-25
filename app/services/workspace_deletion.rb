class WorkspaceDeletion
  CLEANUP_ATTEMPTS = 3
  CYCLE_POINTERS = {
    "agent_profiles" => "current_version_id",
    "crew_tasks" => "current_event_id",
    "execution_runs" => %w[current_event_id input_artifact_id],
    "health_scorecards" => "current_version_id",
    "knowledge_sources" => "current_version_id"
  }.freeze

  class CleanupChanged < StandardError; end

  def self.request!(workspace:, membership:, confirmation:, requested_at: Time.current)
    request = Workspace.transaction do
      workspace.lock!
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.owner?
      raise ArgumentError, "Type #{workspace.slug} to confirm deletion." unless confirmation.to_s == workspace.slug

      existing = workspace.workspace_deletion_request
      next existing if existing

      workspace.update!(deletion_requested_at: requested_at)
      workspace.create_workspace_deletion_request!(requested_by: actor.user).tap do |created|
        AuditEvent.record!(
          action: "workspace.deletion_requested", source: :web, workspace:, actor: actor.user,
          subject: created, metadata: {}, occurred_at: requested_at
        )
      end
    end
    WorkspaceDeletionJob.enqueue_after_commit(request)
    request
  end

  def self.retry!(workspace:, membership:)
    request = workspace.workspace_deletion_request || raise(ActiveRecord::RecordNotFound)
    request.with_lock do
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.owner?
      raise ArgumentError, "Workspace deletion is already running." if request.running?

      request.update!(status: :pending, failure_code: nil, started_at: nil, completed_at: nil)
    end
    WorkspaceDeletionJob.enqueue_after_commit(request)
    request
  end

  def self.perform!(request:, engine: nil, object_purger: nil, completed_at: nil)
    workspace_id = request.workspace_id
    connection = ActiveRecord::Base.connection
    connection.execute("SELECT pg_advisory_lock(50, #{connection.quote(workspace_id)})")
    request.reload
    request.with_lock do
      return unless request.pending?

      request.update!(
        status: :running, attempt_count: request.attempt_count + 1,
        failure_code: nil, started_at: Time.current, completed_at: nil
      )
    end
    workspace = request.workspace

    CLEANUP_ATTEMPTS.times do
      attachments = purge_attachment_objects!(workspace, object_purger:)
      memories = purge_memory_index!(workspace, engine:)
      tombstone = finalize_if_stable!(
        workspace, request, attachments:, memories:, completed_at: completed_at || Time.current
      )
      return tombstone if tombstone
    end
    raise CleanupChanged, "workspace changed during deletion cleanup"
  rescue StandardError => error
    fail_request!(request, error) if request&.persisted? && WorkspaceDeletionRequest.exists?(request.id)
    nil
  ensure
    connection&.execute("SELECT pg_advisory_unlock(50, #{connection.quote(workspace_id)})") if workspace_id
  end

  def self.purge_attachment_objects!(workspace, object_purger:)
    workspace.stored_attachments.includes(file_attachment: :blob).filter_map do |attachment|
      next unless attachment.file.attached?

      blob = attachment.file.blob
      object_purger ? object_purger.call(blob) : blob.service.delete(blob.key)
      [ blob.id, blob.key ]
    end.sort
  end
  private_class_method :purge_attachment_objects!

  def self.purge_memory_index!(workspace, engine:)
    adapter = engine
    workspace.memory_records.joins(:memory_index_entry)
      .where.not(memory_index_entries: { external_document_id: nil }).order(:id).map do |record|
        adapter ||= SupermemoryEngine.default
        adapter.remove(
          organization_key: workspace.organization_id.to_s,
          workspace_key: workspace.runner_key,
          memory_key: record.memory_key
        )
        [ record.id, record.memory_key ]
      end
  end
  private_class_method :purge_memory_index!

  def self.finalize_if_stable!(workspace, request, attachments:, memories:, completed_at:)
    Workspace.transaction do
      workspace.lock!
      return unless attachment_snapshot(workspace) == attachments && memory_snapshot(workspace) == memories
      return if workspace.memory_index_entries.where(status: :indexing).exists?

      tables = workspace_tables
      record_count = tables.sum { |table| table_count(table, workspace.id) }
      tombstone = WorkspaceTombstone.create!(
        former_workspace_id: workspace.id, organization_id: workspace.organization_id,
        deleted_by: request.requested_by, workspace_slug: workspace.slug,
        requested_at: workspace.deletion_requested_at, deleted_at: completed_at,
        record_count:, attachment_count: attachments.size, memory_count: memories.size
      )
      delete_workspace_records!(workspace, tables)
      AuditEvent.record!(
        action: "workspace.deleted", source: :job, actor: request.requested_by,
        subject: tombstone,
        metadata: { record_count:, attachment_count: attachments.size, memory_count: memories.size },
        occurred_at: completed_at
      )
      tombstone
    end
  end
  private_class_method :finalize_if_stable!

  def self.attachment_snapshot(workspace)
    ActiveStorage::Attachment.where(record_type: "StoredAttachment", record_id: workspace.stored_attachment_ids)
      .joins(:blob).order("active_storage_blobs.id").pluck("active_storage_blobs.id", "active_storage_blobs.key")
  end
  private_class_method :attachment_snapshot

  def self.memory_snapshot(workspace)
    workspace.memory_records.joins(:memory_index_entry)
      .where.not(memory_index_entries: { external_document_id: nil }).order(:id).pluck(:id, :memory_key)
  end
  private_class_method :memory_snapshot

  def self.delete_workspace_records!(workspace, tables)
    connection = ActiveRecord::Base.connection
    trigger_tables = tables + %w[active_storage_attachments active_storage_blobs]
    trigger_tables.each do |table|
      connection.execute("ALTER TABLE #{connection.quote_table_name(table)} DISABLE TRIGGER USER")
    end
    CYCLE_POINTERS.each do |table, column|
      next unless tables.include?(table)

      relation = Arel::Table.new(table)
      update = Arel::UpdateManager.new
      update.table(relation)
      update.set(Array(column).map { |name| [ relation[name], nil ] })
      update.where(relation[:workspace_id].eq(workspace.id))
      connection.update(update, "Clear workspace deletion cycle")
    end
    delete_active_storage!(workspace)
    deletion_order(tables).each do |table|
      connection.execute(
        "DELETE FROM #{connection.quote_table_name(table)} WHERE workspace_id = #{connection.quote(workspace.id)}"
      )
    end
    Workspace.where(id: workspace.id).delete_all
    connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    trigger_tables.each do |table|
      connection.execute("ALTER TABLE #{connection.quote_table_name(table)} ENABLE TRIGGER USER")
    end
  end
  private_class_method :delete_workspace_records!

  def self.delete_active_storage!(workspace)
    attachment_scope = ActiveStorage::Attachment.where(
      record_type: "StoredAttachment", record_id: workspace.stored_attachment_ids
    )
    blob_ids = attachment_scope.pluck(:blob_id)
    attachment_scope.delete_all
    ActiveStorage::Blob.where(id: blob_ids).where.missing(:attachments).delete_all
  end
  private_class_method :delete_active_storage!

  def self.workspace_tables
    ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'workspace_id'
      ORDER BY table_name
    SQL
  end
  private_class_method :workspace_tables

  def self.table_count(table, workspace_id)
    connection = ActiveRecord::Base.connection
    connection.select_value(
      "SELECT COUNT(*) FROM #{connection.quote_table_name(table)} WHERE workspace_id = #{connection.quote(workspace_id)}"
    ).to_i
  end
  private_class_method :table_count

  def self.deletion_order(tables)
    rows = ActiveRecord::Base.connection.select_all(<<~SQL)
      SELECT DISTINCT source.relname AS source_table, target.relname AS target_table,
        source_column.attname AS source_column
      FROM pg_constraint constraint_record
      JOIN pg_class source ON source.oid = constraint_record.conrelid
      JOIN pg_class target ON target.oid = constraint_record.confrelid
      JOIN pg_namespace source_namespace ON source_namespace.oid = source.relnamespace
      CROSS JOIN LATERAL unnest(constraint_record.conkey, constraint_record.confkey)
        AS key_columns(source_number, target_number)
      JOIN pg_attribute source_column ON source_column.attrelid = source.oid AND source_column.attnum = key_columns.source_number
      JOIN pg_attribute target_column ON target_column.attrelid = target.oid AND target_column.attnum = key_columns.target_number
      WHERE constraint_record.contype = 'f' AND source_namespace.nspname = 'public'
        AND target_column.attname = 'id'
    SQL
    dependencies = tables.to_h { |table| [ table, [] ] }
    rows.each do |row|
      source = row.fetch("source_table")
      target = row.fetch("target_table")
      next unless dependencies.key?(source) && dependencies.key?(target) && source != target
      next if Array(CYCLE_POINTERS[source]).include?(row.fetch("source_column"))

      dependencies.fetch(source) << target
    end
    insertion = []
    until dependencies.empty?
      ready = dependencies.filter_map { |table, needs| table if (needs.uniq - insertion).empty? }.sort
      raise CleanupChanged, "workspace records contain an unsupported reference cycle" if ready.empty?

      insertion.concat(ready)
      dependencies.except!(*ready)
    end
    insertion.reverse
  end
  private_class_method :deletion_order

  def self.fail_request!(request, error)
    code = error.is_a?(Timeout::Error) ? "timeout_error" : error.class.name.demodulize.underscore
    code = code.gsub(/[^a-z0-9_]/, "_").first(100)
    code = "deletion_error" unless code.match?(/\A[a-z]/)
    request.with_lock do
      request.update!(status: :failed, failure_code: code, completed_at: Time.current)
      AuditEvent.record!(
        action: "workspace.deletion_failed", source: :job, workspace: request.workspace,
        actor_kind: :system, subject: request, metadata: { failure_code: code }
      )
    end
    Rails.logger.error("Workspace deletion request #{request.id} failed: #{error.class}")
  end
  private_class_method :fail_request!
end
