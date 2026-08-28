class IntercomHistoricalBackfill
  MAX_RECORDS = 500
  MANIFEST_TTL = 30.minutes
  DEFAULT_BATCH_SIZE = 25
  COUNT_KEYS = %w[discovered imported matched skipped ambiguous unsupported failed pending attachments notes].freeze
  SUPPORTED_CONVERSATION_FIELDS = %w[
    type id created_at updated_at state title contacts source conversation_parts tags company companies
    admin_assignee_id team_assignee_id open priority read waiting_since snoozed_until
  ].freeze
  SUPPORTED_PART_FIELDS = %w[id part_type created_at updated_at body author attachments redacted].freeze
  Snapshot = Data.define(:records, :counts, :available_from, :available_to, :source_digest, :exceptions)

  class StaleManifest < StandardError; end
  class BoundaryChanged < StandardError; end

  def self.preview!(connection:, membership:, client: IntercomClient.new(connection:), discovered_at: Time.current)
    new(connection:, client:).preview!(membership:, discovered_at:)
  end

  def self.confirm!(connection:, manifest:, membership:, client: IntercomClient.new(connection:),
    confirmed_at: Time.current, enqueue: true, expected_digest: manifest.source_digest)
    new(connection:, client:).confirm!(manifest:, membership:, confirmed_at:, enqueue:, expected_digest:)
  end

  def self.perform!(run:, client: IntercomClient.new(connection: run.intercom_connection),
    batch_size: DEFAULT_BATCH_SIZE, scanner: AttachmentScanner.default)
    new(connection: run.intercom_connection, client:, scanner:).perform!(run:, batch_size:)
  end

  def self.resume!(run:, membership:, client: IntercomClient.new(connection: run.intercom_connection), enqueue: true)
    new(connection: run.intercom_connection, client:).resume!(run:, membership:, enqueue:)
  end

  def initialize(connection:, client:, scanner: AttachmentScanner.default)
    @connection = connection
    @workspace = connection.workspace
    @client = client
    @scanner = scanner
  end

  def preview!(membership:, discovered_at:)
    actor = integration_actor!(membership)
    raise ArgumentError, "Intercom connection is not active" unless @connection.active?

    snapshot = discover
    IntercomBackfillManifest.transaction do
      @connection.lock!
      @connection.intercom_backfill_manifests.current.update_all(status: "stale", updated_at: discovered_at)
      manifest = @connection.intercom_backfill_manifests.create!(
        workspace: @workspace, created_by_membership: actor, created_by_user: actor.user,
        source_digest: snapshot.source_digest, discovery_records: snapshot.records, counts: snapshot.counts,
        available_from: snapshot.available_from, available_to: snapshot.available_to,
        discovered_at:, expires_at: discovered_at + MANIFEST_TTL
      )
      snapshot.exceptions.each { |attributes| record_exception!(manifest:, **attributes) }
      audit!("intercom.backfill_previewed", manifest, actor, conversation_count: snapshot.counts.fetch("conversations"))
      manifest
    end
  end

  def confirm!(manifest:, membership:, confirmed_at:, enqueue:, expected_digest:)
    actor = integration_actor!(membership)
    scoped_manifest = @connection.intercom_backfill_manifests.find(manifest.id)
    raise StaleManifest, "The dry run digest does not match." unless secure_equal?(expected_digest.to_s, scoped_manifest.source_digest)
    raise StaleManifest, "The dry run is missing, stale, changed, or already used." unless scoped_manifest.fresh?(confirmed_at)
    snapshot = discover
    unless secure_equal?(snapshot.source_digest, scoped_manifest.source_digest)
      scoped_manifest.with_lock { scoped_manifest.update!(status: :stale) if scoped_manifest.current? }
      raise StaleManifest, "Intercom changed after this dry run. Start a new dry run."
    end

    run = IntercomBackfillRun.transaction do
      @connection.lock!
      current = @connection.intercom_backfill_manifests.lock.find(scoped_manifest.id)
      raise StaleManifest, "The dry run is missing, stale, changed, or already used." unless current.fresh?(confirmed_at)
      raise StaleManifest, "The dry run boundary changed." unless secure_equal?(current.source_digest, snapshot.source_digest)

      current.update!(status: :consumed, consumed_at: confirmed_at)
      @connection.intercom_backfill_runs.create!(
        workspace: @workspace, intercom_backfill_manifest: current,
        confirmed_by_membership: actor, confirmed_by_user: actor.user,
        source_digest: current.source_digest, counts: initial_run_counts(current), confirmed_at:
      ).tap do |created|
        current.intercom_backfill_exceptions.update_all(intercom_backfill_run_id: created.id, updated_at: confirmed_at)
        audit!("intercom.backfill_confirmed", created, actor, conversation_count: current.counts.fetch("conversations"))
      end
    end
    IntercomBackfillJob.enqueue_after_commit(run) if enqueue
    run
  end

  def resume!(run:, membership:, enqueue:)
    actor = integration_actor!(membership)
    scoped_run = @connection.intercom_backfill_runs.find(run.id)
    scoped_run.with_lock do
      raise ArgumentError, "This backfill cannot resume." unless scoped_run.failed? ||
        (scoped_run.blocked? && scoped_run.intercom_backfill_exceptions.open.none? { |item| item.exception_kind == "ambiguous_identity" })

      scoped_run.update!(status: :pending, failure_code: nil, completed_at: nil)
      audit!("intercom.backfill_resumed", scoped_run, actor, cursor_position: scoped_run.cursor_position)
    end
    IntercomBackfillJob.enqueue_after_commit(scoped_run) if enqueue
    scoped_run
  end

  def perform!(run:, batch_size:)
    raise ArgumentError, "batch size must be between 1 and 50" unless batch_size.to_i.between?(1, 50)

    run = @connection.intercom_backfill_runs.find(run.id)
    records = run.intercom_backfill_manifest.discovery_records
    batch = claim_batch!(run, records.length, batch_size.to_i)
    return run unless batch

    records[batch.start_position...batch.end_position].each_with_index do |record, offset|
      position = batch.start_position + offset
      return run if process_record!(run, batch, record, position) == :stop
    end
    finish_batch!(run, batch)
    complete!(run) if run.reload.cursor_position >= records.length
    run
  rescue IntercomClient::Error => error
    fail_run!(run, batch, "remote_unavailable", error)
  rescue ActiveRecord::ActiveRecordError, AttachmentIntake::InvalidAttachment => error
    record_persistence_exception!(run, records, error)
    fail_run!(run, batch, "persistence_failed", error)
  end

  private
    def discover
      cursor = nil
      remotes = []
      loop do
        response = @client.conversations(starting_after: cursor)
        summaries = Array(response["conversations"])
        summaries.each do |summary|
          raise BoundaryChanged, "Intercom history exceeds the #{MAX_RECORDS} conversation limit." if remotes.length >= MAX_RECORDS

          remotes << @client.conversation(summary.fetch("id"))
        end
        cursor = pagination_cursor(response)
        break unless cursor
      end
      build_snapshot(remotes)
    end

    def build_snapshot(remotes)
      counts = {
        "conversations" => remotes.length, "parts" => 0, "notes" => 0, "attachments" => 0,
        "deterministic_matches" => 0, "ambiguous" => 0, "unsupported_fields" => 0,
        "expected_exceptions" => 0
      }
      exceptions = []
      identity_keys = Set.new
      records = remotes.sort_by { |remote| remote.fetch("id").to_s }.map do |remote|
        remote_id = remote.fetch("id").to_s
        remote_digest = source_digest(remote)
        parts = [ remote["source"], *Array(remote.dig("conversation_parts", "conversation_parts")) ].compact
        counts["parts"] += parts.length
        counts["notes"] += parts.count { |part| part["part_type"].to_s == "note" }
        counts["attachments"] += parts.sum { |part| Array(part["attachments"]).length }
        unsupported = remote.keys - SUPPORTED_CONVERSATION_FIELDS
        unsupported += parts.flat_map { |part| part.keys - SUPPORTED_PART_FIELDS }
        unsupported.uniq.each do |field|
          counts["unsupported_fields"] += 1
          exceptions << exception_attributes(
            type: "field", id: "#{remote_id}:#{field}".first(255), digest: remote_digest,
            kind: "unsupported_field", action: "inspect_source", detail: "Intercom field #{field.to_s.first(100)} is retained as unsupported evidence."
          )
        end
        identities_for(remote).each do |identity|
          key = [ identity.fetch(:kind), identity.fetch(:id) ]
          next unless identity_keys.add?(key)

          if preview_identity(identity) == :ambiguous
            counts["ambiguous"] += 1
            exceptions << exception_attributes(
              type: "identity", id: identity.fetch(:id), digest: remote_digest,
              kind: "ambiguous_identity", action: "review_identity", detail: "Identity has more than one exact Workspace match."
            )
          else
            counts["deterministic_matches"] += 1
          end
        end
        {
          "id" => remote_id, "source_digest" => remote_digest,
          "created_at" => Integer(remote["created_at"] || 0), "updated_at" => Integer(remote["updated_at"] || remote["created_at"] || 0),
          "parts" => parts.length, "notes" => parts.count { |part| part["part_type"].to_s == "note" },
          "attachments" => parts.sum { |part| Array(part["attachments"]).length }
        }
      end
      counts["expected_exceptions"] = exceptions.length
      times = records.flat_map { |record| [ record.fetch("created_at"), record.fetch("updated_at") ] }.reject(&:zero?)
      digest = source_digest(records)
      raise BoundaryChanged, "The dry-run manifest is too large." if records.to_json.bytesize > IntercomBackfillManifest::MAX_DISCOVERY_BYTES

      Snapshot.new(
        records:, counts:, available_from: (Time.zone.at(times.min) if times.any?),
        available_to: (Time.zone.at(times.max) if times.any?), source_digest: digest, exceptions:
      )
    end

    def identities_for(remote)
      contact = Array(remote.dig("contacts", "contacts")).first || remote.dig("source", "author")
      company = remote["company"] || Array(remote.dig("companies", "companies")).first
      [ identity_data(:contact, contact), identity_data(:account, company) ].compact
    end

    def identity_data(kind, item)
      return unless item.is_a?(Hash) && item["id"].present?

      keys = if kind == :contact
        item["email"].present? ? { email: IdentityKeyNormalizer.normalize(:email, item["email"]) } : {}
      else
        domain = item["website"].to_s.sub(%r{\Ahttps?://}i, "").split("/").first
        domain.present? ? { domain: IdentityKeyNormalizer.normalize(:domain, domain) } : {}
      end
      { kind:, id: item.fetch("id").to_s, keys: }
    end

    def preview_identity(identity)
      existing = @workspace.source_identities.find_by(
        source_namespace: "intercom:#{@connection.id}", source_record_type: identity.fetch(:kind),
        source_record_id: identity.fetch(:id)
      )
      return :ambiguous if existing&.ambiguous?
      return :matched if existing
      return :matched if identity.fetch(:keys).empty?

      roots = identity.fetch(:keys).flat_map do |kind, value|
        SourceIdentityKey.current.where(workspace: @workspace, kind:, normalized_value: value)
          .includes(source_identity: [ :account, :contact ]).filter_map do |key|
          source = key.source_identity
          source.canonical_record&.canonical if source.matched? && source.entity_kind == identity.fetch(:kind).to_s && !source.retired_at?
        end
      end.uniq
      roots.length > 1 ? :ambiguous : :matched
    end

    def claim_batch!(run, record_count, batch_size)
      run.with_lock do
        return if run.completed? || run.blocked?
        return if run.running?
        return complete!(run) if run.cursor_position >= record_count

        run.update!(status: :running, failure_code: nil, started_at: run.started_at || Time.current)
        ending = [ run.cursor_position + batch_size, record_count ].min
        attempt_number = run.intercom_backfill_batches.where(start_position: run.cursor_position).maximum(:attempt_number).to_i + 1
        run.intercom_backfill_batches.create!(
          workspace: @workspace, start_position: run.cursor_position, end_position: ending,
          attempt_number:, status: :running, source_digest: run.source_digest, counts: {}, started_at: Time.current
        )
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def process_record!(run, batch, record, position)
      remote = @client.conversation(record.fetch("id"))
      digest = source_digest(remote)
      unless secure_equal?(digest, record.fetch("source_digest"))
        record_exception!(
          manifest: run.intercom_backfill_manifest, run:, type: "conversation", id: record.fetch("id"), digest:,
          kind: "source_changed", action: "restart_preview", detail: "Intercom changed after confirmation. Start a new dry run."
        )
        block_run!(run, batch, "source_changed")
        return :stop
      end

      prepared_attachments = []
      IntercomBackfillRun.transaction(requires_new: true) do
        link, outcome = IntercomSync.new(connection: @connection, client: @client).sync_historical_conversation!(remote)
        import_attachments!(run, link, remote, prepared_attachments:)
        commit_boundary!(run, batch, record, position, outcome)
      end
      :continue
    rescue IntercomSync::IdentityAmbiguous
      prepared_attachments&.each(&:purge!)
      identity = persist_ambiguous_identity!(remote)
      record_exception!(
        manifest: run.intercom_backfill_manifest, run:, source_identity: identity,
        type: "identity", id: identity&.source_record_id || record.fetch("id"), digest: record.fetch("source_digest"),
        kind: "ambiguous_identity", action: "review_identity", detail: "Choose one recorded identity candidate, then resume."
      )
      block_run!(run, batch, "identity_ambiguous")
      :stop
    rescue StandardError
      prepared_attachments&.each(&:purge!)
      raise
    end

    def persist_ambiguous_identity!(remote)
      item = identities_for(remote).find { |identity| preview_identity(identity) == :ambiguous }
      return unless item

      result = SourceIdentityResolver.resolve!(
        workspace: @workspace, entity_kind: item.fetch(:kind),
        source_namespace: "intercom:#{@connection.id}", source_record_type: item.fetch(:kind),
        source_record_id: item.fetch(:id), keys: item.fetch(:keys),
        attributes: { name: identity_name(remote, item.fetch(:kind)) }
      )
      result.source_identity if result.ambiguous?
    end

    def identity_name(remote, kind)
      item = if kind == :contact
        Array(remote.dig("contacts", "contacts")).first || remote.dig("source", "author")
      else
        remote["company"] || Array(remote.dig("companies", "companies")).first
      end
      item&.fetch("name", nil).to_s.strip.presence || ("Intercom company" if kind == :account)
    end

    def import_attachments!(run, link, remote, prepared_attachments:)
      parts = [ remote["source"], *Array(remote.dig("conversation_parts", "conversation_parts")) ].compact
      parts.each do |remote_part|
        part_id = remote_part["id"].presence || "conversation:#{remote.fetch('id')}"
        part_link = link.intercom_part_links.find_by!(remote_part_id: part_id.to_s)
        attachments = Array(remote_part["attachments"])
        attachments.drop(AttachmentIntake::MAX_FILES).each do |item|
          record_exception!(
            manifest: run.intercom_backfill_manifest, run:, type: "attachment",
            id: (item["id"].presence || source_digest(item)).to_s, digest: source_digest(item),
            kind: "attachment_rejected", action: "inspect_attachment",
            detail: "Attachment exceeds the per-message file-count limit."
          )
        end
        attachments.first(AttachmentIntake::MAX_FILES).each do |item|
          attachment_id = (item["id"].presence || source_digest(item)).to_s.first(255)
          next if part_link.intercom_part_attachments.exists?(remote_attachment_id: attachment_id)

          begin
            data = @client.attachment(item.fetch("url"))
            prepared = AttachmentIntake.prepare!([ { filename: item["name"].presence || "attachment", data: } ], scanner: @scanner)
            prepared_attachments.concat(prepared)
            attachment = AttachmentIntake.persist!(
              workspace: @workspace, prepared:, source: :intercom_import, message: part_link.conversation_message
            ).sole
            part_link.intercom_part_attachments.create!(
              workspace: @workspace, stored_attachment: attachment, remote_attachment_id: attachment_id
            )
            if attachment.rejected?
              record_attachment_exception!(run, item, attachment, "attachment_rejected", "inspect_attachment")
            elsif attachment.quarantined?
              record_attachment_exception!(run, item, attachment, "attachment_unavailable", "inspect_attachment")
            end
          rescue IntercomClient::Error, KeyError, AttachmentIntake::InvalidAttachment => error
            record_exception!(
              manifest: run.intercom_backfill_manifest, run:, type: "attachment", id: attachment_id,
              digest: source_digest(item), kind: "attachment_unavailable", action: "inspect_attachment",
              detail: "Attachment could not be preserved: #{error.class.name.demodulize}."
            )
          end
        end
      end
    end

    def record_attachment_exception!(run, item, attachment, kind, action)
      record_exception!(
        manifest: run.intercom_backfill_manifest, run:, type: "attachment",
        id: (item["id"].presence || attachment.id).to_s, digest: attachment.content_sha256,
        kind:, action:, detail: "Attachment is #{attachment.scan_status}: #{attachment.scan_result_code.to_s.first(100)}."
      )
    end

    def record_persistence_exception!(run, records, error)
      return unless run&.persisted? && records

      record = records[run.cursor_position]
      return unless record

      record_exception!(
        manifest: run.intercom_backfill_manifest, run:, type: "conversation",
        id: record.fetch("id"), digest: record.fetch("source_digest"),
        kind: "persistence_failed", action: "resume",
        detail: "The record did not reach a definite commit boundary: #{error.class.name.demodulize}."
      )
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def commit_boundary!(run, batch, record, position, outcome)
      run.with_lock do
        return unless run.running? && run.cursor_position == position

        counts = run.counts.merge(
          outcome.to_s => run.counts.fetch(outcome.to_s, 0) + 1,
          "failed" => 0, "ambiguous" => 0
        )
        run.update!(
          cursor_position: position + 1, counts:, last_definite_remote_id: record.fetch("id"),
          last_definite_source_digest: record.fetch("source_digest")
        )
        batch.update!(counts: counts.slice("imported", "matched", "skipped"), last_definite_remote_id: record.fetch("id"))
      end
    end

    def finish_batch!(run, batch)
      run.with_lock do
        return unless run.running?

        batch.update!(status: :completed, completed_at: Time.current)
        run.update!(status: :pending)
      end
    end

    def complete!(run)
      run.with_lock do
        return run if run.completed?

        counts = final_counts(run)
        report = run.create_intercom_backfill_report!(
          workspace: @workspace, status: :complete, counts:, report_digest: source_digest(counts), generated_at: Time.current
        )
        raise ActiveRecord::RecordInvalid, report unless report.reconciled?

        run.update!(status: :completed, counts:, failure_code: nil, completed_at: Time.current)
        AuditEvent.record!(
          action: "intercom.backfill_completed", source: :job, workspace: @workspace,
          actor_kind: :system, subject: run, metadata: { conversation_count: counts.fetch("discovered") }
        )
      end
      run
    end

    def block_run!(run, batch, code)
      run.with_lock do
        batch.update!(status: :blocked, completed_at: Time.current)
        counts = final_counts(run, ambiguous: code == "identity_ambiguous" ? 1 : 0)
        run.update!(status: :blocked, counts:, failure_code: code, completed_at: Time.current)
      end
    end

    def fail_run!(run, batch, code, error)
      return run unless run&.persisted?

      run.with_lock do
        batch&.update!(status: :failed, completed_at: Time.current) if batch&.running?
        run.update!(status: :failed, counts: final_counts(run, failed: 1), failure_code: code, completed_at: Time.current)
      end
      Rails.logger.error("Intercom backfill run #{run.id} stopped: #{error.class}")
      run
    end

    def final_counts(run, ambiguous: nil, failed: nil)
      discovered = run.intercom_backfill_manifest.counts.fetch("conversations")
      counts = initial_run_counts(run.intercom_backfill_manifest).merge(run.counts)
      counts["ambiguous"] = ambiguous unless ambiguous.nil?
      counts["failed"] = failed unless failed.nil?
      counts["unsupported"] = run.intercom_backfill_exceptions.open.where(
        exception_kind: %w[unsupported_field attachment_rejected attachment_unavailable]
      ).count
      decided = %w[imported matched skipped ambiguous failed].sum { |key| counts.fetch(key, 0) }
      counts["pending"] = [ discovered - decided, 0 ].max
      counts
    end

    def initial_run_counts(manifest)
      COUNT_KEYS.index_with { 0 }.merge(
        "discovered" => manifest.counts.fetch("conversations"),
        "pending" => manifest.counts.fetch("conversations"),
        "attachments" => manifest.counts.fetch("attachments"), "notes" => manifest.counts.fetch("notes")
      )
    end

    def record_exception!(manifest:, type:, id:, digest:, kind:, action:, detail:, run: nil, source_identity: nil)
      exception = manifest.intercom_backfill_exceptions.find_or_initialize_by(
        remote_record_type: type, remote_record_id: id.to_s.first(255), exception_kind: kind
      )
      exception.update!(
        workspace: @workspace, intercom_backfill_run: run || exception.intercom_backfill_run,
        source_identity: source_identity || exception.source_identity, source_digest: digest,
        recovery_action: action, detail: detail.to_s.first(IntercomBackfillException::MAX_DETAIL_BYTES)
      )
      exception
    end

    def exception_attributes(type:, id:, digest:, kind:, action:, detail:)
      { type:, id:, digest:, kind:, action:, detail: }
    end

    def integration_actor!(membership)
      actor = @workspace.memberships.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_configure_integrations?
      raise ActiveRecord::RecordNotFound if @workspace.deletion_requested?

      actor
    end

    def audit!(action, subject, actor, metadata)
      AuditEvent.record!(
        action:, source: :web, workspace: @workspace, actor: actor.user, subject:, metadata:
      )
    end

    def pagination_cursor(response)
      value = response.dig("pages", "next")
      return value["starting_after"].presence if value.is_a?(Hash)
      return if value.blank?

      URI.decode_www_form(URI(value.to_s).query.to_s).to_h["starting_after"].presence
    rescue URI::InvalidURIError
      raise IntercomClient::Unavailable, "Intercom returned an invalid pagination cursor"
    end

    def source_digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value.fetch(key)) ] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def secure_equal?(left, right)
      left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
end
