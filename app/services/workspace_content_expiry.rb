class WorkspaceContentExpiry
  STALE_AFTER = 1.hour

  def self.request!(workspace:, membership: nil, source: :job, requested_at: Time.current)
    run = WorkspaceContentExpiryRun.transaction do
      policy = workspace.workspace_data_policy.lock!
      cutoff = policy.content_cutoff(at: requested_at)
      raise ArgumentError, "content retention is not enabled" unless cutoff

      actor = nil
      if membership
        actor = workspace.memberships.lock.find(membership.id)
        raise Current::RoleAccessDenied unless actor.owner?
      end

      stale = workspace.workspace_content_expiry_runs.lock.running.where("started_at < ?", requested_at - STALE_AFTER)
      stale.update_all(status: "failed", failure_code: "interrupted", completed_at: requested_at, updated_at: requested_at)
      current = workspace.workspace_content_expiry_runs.lock.where(status: %w[pending running]).first
      next current if current

      workspace.workspace_content_expiry_runs.create!(cutoff_at: cutoff).tap do |created|
        AuditEvent.record!(
          action: "workspace.content_expiry_requested", source:, workspace:, actor: actor&.user,
          actor_kind: actor ? nil : :system, subject: created, metadata: {}, occurred_at: requested_at
        )
      end
    end
    WorkspaceContentExpiryJob.enqueue_after_commit(run) if run.pending?
    run
  end

  def self.perform!(run:, engine: nil, object_purger: nil, started_at: Time.current)
    connection = ActiveRecord::Base.connection
    connection.execute("SELECT pg_advisory_lock(48, #{connection.quote(run.workspace_id)})")
    run.with_lock do
      return run if run.completed?
      run.update!(status: :running, failure_code: nil, started_at:, completed_at: nil)
    end

    object_purger ? object_purger.call(run) : purge_attachment_objects!(run)
    purge_memory_index!(run, engine:)
    count = connection.select_value(
      "SELECT expire_workspace_content(#{connection.quote(run.workspace_id)}, #{connection.quote(run.cutoff_at)})"
    ).to_i
    finish!(run, count:, completed_at: Time.current)
  rescue StandardError => error
    fail!(run, error, completed_at: Time.current)
  ensure
    connection&.execute("SELECT pg_advisory_unlock(48, #{connection.quote(run.workspace_id)})")
  end

  def self.purge_attachment_objects!(run)
    run.workspace.stored_attachments.where("created_at < ?", run.cutoff_at)
      .includes(file_attachment: :blob).find_each do |attachment|
        attachment.file.blob.service.delete(attachment.file.blob.key) if attachment.file.attached?
      end
  end
  private_class_method :purge_attachment_objects!

  def self.purge_memory_index!(run, engine:)
    adapter = engine
    run.workspace.memory_records.where("observed_at < ?", run.cutoff_at)
      .joins(:memory_index_entry).where.not(memory_index_entries: { external_document_id: nil }).find_each do |record|
        adapter ||= SupermemoryEngine.default
        adapter.remove(
          organization_key: record.workspace.organization_id.to_s,
          workspace_key: record.workspace.runner_key,
          memory_key: record.memory_key
        )
      end
  end
  private_class_method :purge_memory_index!

  def self.finish!(run, count:, completed_at:)
    run.with_lock do
      run.update!(status: :completed, expired_record_count: count, failure_code: nil, completed_at:)
      AuditEvent.record!(
        action: "workspace.content_expiry_completed", source: :job, workspace: run.workspace,
        actor_kind: :system, subject: run, metadata: { record_count: count }, occurred_at: completed_at
      )
    end
    run
  end
  private_class_method :finish!

  def self.fail!(run, error, completed_at:)
    code = error.class.name.demodulize.underscore.gsub(/[^a-z0-9_]/, "_").first(100)
    code = "expiry_error" unless code.match?(/\A[a-z]/)
    run.with_lock do
      run.update!(status: :failed, failure_code: code, completed_at:)
      AuditEvent.record!(
        action: "workspace.content_expiry_failed", source: :job, workspace: run.workspace,
        actor_kind: :system, subject: run, metadata: { failure_code: code }, occurred_at: completed_at
      )
    end
    Rails.logger.error("Workspace content expiry run #{run.id} failed: #{error.class}")
    run
  end
  private_class_method :fail!
end
