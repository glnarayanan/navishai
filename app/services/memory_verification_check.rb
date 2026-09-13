# Owner-triggered scoped round trip against the configured self-hosted memory engine.
#
# It writes one harmless synthetic Memory record through the internal contract,
# proves indexing and Workspace-scoped retrieval, proves another Workspace cannot
# retrieve it, then tombstones and removes it. The outcome is an append-only
# OperationalCheck bound to a non-secret configuration digest, so a later address
# or pending-first-boot change cannot inherit an earlier pass. Failed and pending
# results never count as verified. The check never calls a managed memory host.
class MemoryVerificationCheck
  class NotConfigured < StandardError; end
  class SourceCommitUnavailable < StandardError; end
  class CleanupPending < StandardError; end

  CHECK_KIND = "memory_verification".freeze
  TOPIC = "memory-verification".freeze
  SOURCE_REFERENCE_PREFIX = "navishai://memory-verification/".freeze
  FRESH_FOR = 30.days
  RETENTION = 7.days
  INDEX_POLL_ATTEMPTS = 5
  INDEX_POLL_SECONDS = 2
  LOCK_KEY = 49
  DELETION_REASON = "Synthetic memory verification cleanup".freeze

  Outcome = Data.define(:result, :result_code, :check)

  def self.configuration_digest(env = ENV)
    Digest::SHA256.hexdigest([
      env["NAVISHAI_SUPERMEMORY_ADDRESS"].to_s.strip,
      env["NAVISHAI_MEMORY_PENDING"].to_s.strip
    ].join("\n"))
  end

  def self.configured?(env = ENV)
    return false if env["NAVISHAI_MEMORY_PENDING"] == "1"

    engine_from(env)
    true
  rescue SupermemoryEngine::ConfigurationError
    false
  end

  def self.latest_for_current_configuration(workspace, env = ENV)
    workspace.operational_checks.where(check_kind: CHECK_KIND, evidence_digest: configuration_digest(env)).latest_first.first
  end

  def self.engine_from(env = ENV)
    SupermemoryEngine.new(
      address: env["NAVISHAI_SUPERMEMORY_ADDRESS"],
      api_key: env["NAVISHAI_SUPERMEMORY_API_KEY"].presence ||
        Rails.application.credentials.dig(:memory, :supermemory_api_key)
    )
  end

  def self.run!(workspace:, membership:, engine: nil, foreign_workspace: nil, env: ENV,
    now: Time.current, sleeper: default_sleeper, poll_attempts: INDEX_POLL_ATTEMPTS)
    new(workspace:, membership:, engine:, foreign_workspace:, env:, now:, sleeper:, poll_attempts:).run!
  end

  def self.continue!(workspace:, membership: nil, engine: nil, foreign_workspace: nil, env: ENV,
    now: Time.current, sleeper: default_sleeper, poll_attempts: INDEX_POLL_ATTEMPTS)
    new(workspace:, membership:, engine:, foreign_workspace:, env:, now:, sleeper:, poll_attempts:).continue!
  end

  def self.default_sleeper
    Rails.env.test? ? ->(_) { } : Kernel.method(:sleep)
  end
  private_class_method :default_sleeper

  def initialize(workspace:, membership:, engine:, foreign_workspace:, env:, now:, sleeper:, poll_attempts:)
    @workspace = workspace
    @membership = membership
    @engine = engine
    @foreign_workspace = foreign_workspace
    @env = env
    @now = now
    @sleeper = sleeper
    @poll_attempts = poll_attempts
  end

  def run!
    with_lock { execute!(resume: false) }
  end

  def continue!
    with_lock { execute!(resume: true) }
  end

  private
    def execute!(resume:)
      raise NotConfigured, "memory first-boot is still pending" if @env["NAVISHAI_MEMORY_PENDING"] == "1"
      actor! if @membership

      adapter = adapter!
      unless adapter.health.available?
        raise SupermemoryEngine::Unavailable, "self-hosted Supermemory is unavailable"
      end

      source_commit = @env["NAVISHAI_SOURCE_COMMIT"].to_s
      raise SourceCommitUnavailable, "source_commit_unavailable" unless source_commit.match?(OperationalCheck::COMMIT_FORMAT)

      reclaim_previous!(adapter) unless resume
      record = live_synthetics.first
      if record.nil?
        return finish_unfinished_cleanup!(adapter, source_commit) if resume
        record = create_synthetic!
      end

      index_synthetic!(record, adapter)
      status = wait_until_indexed!(record, adapter)
      if status == "failed"
        return record_outcome("failed", "retrieval_mismatch", source_commit)
      end
      unless status == "done"
        enqueue_continuation unless resume
        return record_outcome("pending", "indexing_pending", source_commit)
      end

      own_hits = search_workspace!(adapter, @workspace, token_for(record))
      return record_outcome("failed", "retrieval_mismatch", source_commit) unless
        own_hits.any? { |hit| hit.memory_key == record.memory_key }

      foreign = isolation_workspace
      foreign_hits = search_foreign!(adapter, foreign, token_for(record))
      return record_outcome("failed", "scope_failure", source_commit) if
        foreign_hits.any? { |hit| hit.memory_key == record.memory_key }

      unless remove_synthetic!(record, adapter) && !engine_still_has?(adapter, record)
        enqueue_continuation unless resume
        return record_outcome("pending", "cleanup_pending", source_commit)
      end

      record_outcome("passed", "verified", source_commit)
    rescue CleanupPending
      enqueue_continuation unless resume
      record_outcome("pending", "cleanup_pending", @env["NAVISHAI_SOURCE_COMMIT"].to_s)
    rescue SupermemoryEngine::AuthenticationError
      record_outcome("failed", "authentication_failure", @env["NAVISHAI_SOURCE_COMMIT"].to_s)
    rescue SupermemoryEngine::Unavailable, SystemCallError, Timeout::Error
      record_outcome("unavailable", "memory_unavailable", @env["NAVISHAI_SOURCE_COMMIT"].to_s)
    end

    def with_lock
      connection = MemoryRecord.connection
      connection.execute("SELECT pg_advisory_lock(#{LOCK_KEY}, #{connection.quote(@workspace.id)})")
      yield
    ensure
      connection.execute("SELECT pg_advisory_unlock(#{LOCK_KEY}, #{connection.quote(@workspace.id)})")
    end

    def adapter!
      @engine || (@env.equal?(ENV) ? SupermemoryEngine.default : self.class.engine_from(@env))
    rescue SupermemoryEngine::ConfigurationError
      raise NotConfigured, "self-hosted memory is not configured"
    end

    def live_synthetics
      @workspace.memory_records.available.where(topic: TOPIC).order(:id)
    end

    def unfinished_tombstones
      @workspace.memory_tombstones.joins(:memory_record)
        .where(memory_records: { topic: TOPIC })
        .where.not(index_status: :removed)
    end

    def reclaim_previous!(adapter)
      live_synthetics.find_each { |record| remove_synthetic!(record, adapter) }
      unfinished_tombstones.find_each do |tombstone|
        MemoryDeletion.perform!(tombstone:, engine: adapter, attempted_at: @now)
      end
      raise CleanupPending if live_synthetics.exists? || unfinished_tombstones.exists?
    end

    def finish_unfinished_cleanup!(adapter, source_commit)
      unfinished_tombstones.find_each do |tombstone|
        MemoryDeletion.perform!(tombstone:, engine: adapter, attempted_at: @now)
      end
      return record_outcome("pending", "cleanup_pending", source_commit) if unfinished_tombstones.exists?

      nil
    end

    def create_synthetic!
      token = SecureRandom.uuid
      content = "NavishAI memory verification token #{token}. This synthetic record proves scoped indexing and retrieval. It is not customer evidence."
      record = @workspace.memory_records.create!(
        memory_type: :semantic, scope_kind: :workspace, topic: TOPIC, content:,
        authority: :source_record, origin_kind: :system,
        source_reference: "#{SOURCE_REFERENCE_PREFIX}#{@workspace.id}",
        source_digest: Digest::SHA256.hexdigest(content.b),
        capture_key: "memory-verification:#{token}",
        observed_at: @now, valid_from: @now, confidence: 1,
        retention_policy: :time_bound, retention_until: @now + RETENTION
      )
      @workspace.memory_index_entries.create!(memory_record: record)
      record
    end

    def index_synthetic!(record, adapter)
      entry = record.memory_index_entry
      MemoryIndexer.perform!(entry:, engine: adapter, attempted_at: @now) if entry && !entry.indexed?
    end

    def wait_until_indexed!(record, adapter)
      attempts = @poll_attempts
      loop do
        status = adapter.status(
          organization_key: @workspace.organization_id.to_s,
          workspace_key: @workspace.runner_key,
          memory_key: record.memory_key
        )
        return status.status if status.status == "done" || status.status == "failed"
        return status.status if attempts <= 0

        attempts -= 1
        @sleeper.call(INDEX_POLL_SECONDS)
      end
    end

    def search_workspace!(adapter, workspace, token)
      adapter.search(
        query: MemoryEngine::Query.new(
          organization_key: workspace.organization_id.to_s,
          workspace_key: workspace.runner_key,
          text: token,
          scope_filters: [ MemoryEngine::ScopeFilter.new(kind: "workspace", key: workspace.id.to_s) ],
          limit: 5
        )
      )
    end

    def search_foreign!(adapter, foreign, token)
      organization_key = foreign&.organization_id&.to_s || @workspace.organization_id.to_s
      workspace_key = foreign&.runner_key || "00000000-0000-4000-8000-000000000001"
      scope_key = foreign&.id&.to_s || "0"
      adapter.search(
        query: MemoryEngine::Query.new(
          organization_key:,
          workspace_key:,
          text: token,
          scope_filters: [ MemoryEngine::ScopeFilter.new(kind: "workspace", key: scope_key) ],
          limit: 5
        )
      )
    end

    def isolation_workspace
      @foreign_workspace || Workspace.where.not(id: @workspace.id).order(:id).first
    end

    def token_for(record)
      record.content[/\btoken ([0-9a-f-]{36})\b/, 1] || record.content
    end

    def engine_still_has?(adapter, record)
      search_workspace!(adapter, @workspace, token_for(record)).any? { |hit| hit.memory_key == record.memory_key }
    end

    def remove_synthetic!(record, adapter)
      tombstone = @workspace.memory_tombstones.find_by(memory_record: record)
      unless tombstone
        actor = actor!
        tombstone = @workspace.memory_tombstones.create!(
          memory_record: record, deleted_by_membership: actor, deleted_by_user: actor.user,
          reason: DELETION_REASON
        )
        AuditEvent.record!(
          action: "memory.record_deleted", source: @membership ? :web : :system, workspace: @workspace,
          actor: actor.user, subject: record, metadata: {}, occurred_at: @now
        )
      end
      MemoryDeletion.perform!(tombstone:, engine: adapter, attempted_at: @now)
      tombstone.reload.index_status_removed?
    rescue SupermemoryEngine::Unavailable, SupermemoryEngine::AmbiguousResult, SystemCallError, Timeout::Error
      false
    end

    def actor!
      if @membership
        actor = @workspace.memberships.lock.find(@membership.id)
        raise Current::RoleAccessDenied unless actor.owner? || actor.admin?

        return actor
      end

      latest = @workspace.operational_checks.where(check_kind: CHECK_KIND).latest_first.first
      latest&.recorded_by_membership || @workspace.memberships.owners.first ||
        raise(Current::RoleAccessDenied, "memory verification has no authorised actor")
    end

    def enqueue_continuation
      MemoryVerificationJob.enqueue_after_commit(@workspace)
    end

    def record_outcome(result, result_code, source_commit)
      check = OperationalCheck.record!(
        workspace: @workspace, membership: @membership && actor!,
        check_kind: CHECK_KIND, result:, result_code:,
        evidence_digest: self.class.configuration_digest(@env),
        source_commit:, checked_at: @now
      )
      Outcome.new(result:, result_code:, check:)
    end
end
