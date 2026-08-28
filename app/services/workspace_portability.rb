require "digest"
require "json"
require "rubygems/package"
require "set"
require "stringio"
require "tempfile"
require "zlib"

class WorkspacePortability
  FORMAT = "navishai-workspace-v2"
  MAX_ARCHIVE_BYTES = 60.megabytes
  MAX_UNCOMPRESSED_BYTES = 64.megabytes
  MAX_ATTACHMENT_BYTES = 50.megabytes
  USER_ATTRIBUTES = %w[id email_address verified_at].freeze
  ARCHIVE_KEYS = %w[format exported_at organization workspace users tables].freeze
  GLOBAL_KEY_COLUMNS = {
    "crew_artifacts" => "artifact_key",
    "crew_tasks" => "task_key",
    "execution_events" => "event_key",
    "execution_runs" => "run_key",
    "intercom_connections" => "webhook_key",
    "intercom_sync_operations" => "operation_key",
    "knowledge_sources" => "source_key",
    "memory_correction_proposals" => "proposal_key",
    "memory_proposals" => "proposal_key",
    "memory_records" => "memory_key",
    "outbound_webhook_deliveries" => "event_key",
    "public_web_search_results" => "citation_key",
    "shared_email_inboxes" => "webhook_key"
  }.freeze
  REFERENCE_COLUMNS = %w[capture_key source_reference].freeze
  AUDIT_METADATA_ID_TABLES = {
    "assignee_id" => "memberships",
    "attachment_id" => "stored_attachments",
    "policy_id" => "sla_policies",
    "tag_id" => "tags"
  }.freeze
  NON_DEFERRED_FOREIGN_KEYS = %w[
    email_drafts.human_edited_by_membership_id
    email_drafts.source_crew_artifact_id
    execution_runs.usage_rate_version_id
    intercom_drafts.human_edited_by_membership_id
    intercom_drafts.source_crew_artifact_id
    intercom_outbound_deliveries.human_edited_by_membership_id
    intercom_outbound_deliveries.source_crew_artifact_id
    memory_proposals.account_id
    memory_proposals.contact_id
    memory_proposals.support_case_id
    memory_records.account_id
    memory_records.agent_profile_id
    memory_records.contact_id
    memory_records.crew_template_id
    memory_records.organization_id
    memory_records.support_case_id
    memory_records.user_id
    outbound_email_deliveries.human_edited_by_membership_id
    outbound_email_deliveries.source_crew_artifact_id
    customer_success_interventions.approved_by_membership_id
    customer_success_interventions.completed_by_membership_id
    customer_success_interventions.abandoned_by_membership_id
    public_web_searches.usage_rate_version_id
    usage_cost_snapshots.applied_usage_rate_version_id
    usage_cost_snapshots.execution_run_id
    usage_cost_snapshots.public_web_search_id
  ].to_set.freeze
  MAPPED_REFERENCE_COLUMNS = { "conversation_id" => "conversations" }.freeze
  PORTABLE_MEMORY_INDEX_STATE = {
    "status" => "pending",
    "attempt_count" => 0,
    "external_document_id" => nil,
    "external_status" => nil,
    "failure_code" => nil,
    "last_attempted_at" => nil,
    "indexed_at" => nil
  }.freeze
  HEALTH_EVIDENCE_TABLES = {
    "account_health_input" => "account_health_inputs",
    "support_case" => "support_cases",
    "case_sla" => "case_slas",
    "case_note" => "case_notes",
    "conversation_message" => "conversation_messages",
    "support_case_status_change" => "support_case_status_changes",
    "tag" => "tags",
    "crew_artifact" => "crew_artifacts"
  }.freeze

  class InvalidArchive < StandardError; end
  class VerificationFailed < InvalidArchive
    attr_reader :result_code, :detail

    def initialize(result_code, detail: nil)
      @result_code = result_code
      @detail = detail
      super("Workspace archive verification failed: #{result_code.humanize}.")
    end
  end

  ImportResult = Data.define(:workspace, :report)
  VerificationResult = Data.define(:workspace, :operational_check)

  def self.export(workspace:, membership:, exported_at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.owner?

    output = Tempfile.new([ "navishai-workspace", ".tar.gz" ], binmode: true)
    record_count = 0
    attachment_count = 0
    Workspace.transaction(isolation: :repeatable_read) do
      tables = workspace_tables.to_h do |table|
        rows = workspace_rows(table, workspace.id)
        record_count += rows.size
        [ table, rows ]
      end
      users = referenced_users(tables)
      attachments = workspace.stored_attachments.includes(file_attachment: :blob).order(:id).to_a
      raise InvalidArchive, "Workspace attachments exceed the 50 MiB archive limit." if attachments.sum(&:byte_size) > MAX_ATTACHMENT_BYTES
      archive = {
        "format" => FORMAT,
        "exported_at" => exported_at.iso8601(6),
        "organization" => workspace.organization.attributes.slice("name", "slug"),
        "workspace" => workspace.attributes,
        "users" => users,
        "tables" => tables
      }
      gzip = Zlib::GzipWriter.new(output)
      begin
        Gem::Package::TarWriter.new(gzip) do |tar|
          manifest = JSON.generate(archive)
          tar.add_file_simple("manifest.json", 0o600, manifest.bytesize) { |entry| entry.write(manifest) }
          attachments.each do |attachment|
            raise InvalidArchive, "Stored attachment #{attachment.id} has no object." unless attachment.file.attached?

            attachment.file.blob.open do |file|
              digest = Digest::SHA256.new
              tar.add_file_simple("attachment_objects/#{attachment.id}", 0o600, attachment.byte_size) do |entry|
                while (chunk = file.read(64.kilobytes))
                  digest.update(chunk)
                  entry.write(chunk)
                end
              end
              raise InvalidArchive, "Stored attachment #{attachment.id} digest does not match." unless
                ActiveSupport::SecurityUtils.secure_compare(digest.hexdigest, attachment.content_sha256)
            end
            attachment_count += 1
          end
        end
      ensure
        gzip.finish
      end
      raise InvalidArchive, "Workspace archive exceeds the 60 MiB limit." if output.size > MAX_ARCHIVE_BYTES
      AuditEvent.record!(
        action: "workspace.exported", source: :web, workspace:, actor: actor.user, subject: workspace,
        metadata: { table_count: tables.size, record_count:, attachment_count: }, occurred_at: exported_at
      )
    end
    output.rewind
    output
  rescue StandardError
    output&.close!
    raise
  end

  def self.import(workspace:, membership:, archive_io:, name:, slug:, imported_at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.owner?

    archive, attachment_files = parse_archive(archive_io)
    import_archive(
      workspace:, actor:, archive:, attachment_files:, name:, slug:, imported_at:, verify: false
    ).workspace
  rescue ActiveRecord::StatementInvalid
    raise InvalidArchive, "Workspace archive data does not satisfy this release."
  rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, JSON::ParserError, KeyError, TypeError, ArgumentError,
    ActiveRecord::RecordInvalid => error
    raise InvalidArchive, "Workspace archive is invalid: #{error.message}"
  ensure
    attachment_files&.each_value { |object| object.close! }
  end

  def self.verify_round_trip(workspace:, membership:, name:, slug:, source_commit:, checked_at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.owner?
    raise VerificationFailed, "source_commit_invalid" unless source_commit.to_s.match?(OperationalCheck::COMMIT_FORMAT)

    archive_io = export(workspace:, membership: actor, exported_at: checked_at)
    archive, attachment_files = parse_archive(archive_io)
    source_counts = archive_counts(archive)
    check = nil
    imported = import_archive(
      workspace:, actor:, archive:, attachment_files:, name:, slug:, imported_at: checked_at, verify: true
    ) do |_target, report|
      evidence_digest = verification_evidence_digest(
        report:, source_commit:, checked_at:, result_code: "round_trip_verified"
      )
      check = OperationalCheck.record!(
        workspace:, membership: actor, check_kind: "archive_verification", result: "passed",
        result_code: "round_trip_verified", evidence_digest:, source_commit:, checked_at:,
        archive_format: FORMAT, counts: source_counts
      )
    end
    VerificationResult.new(workspace: imported.workspace, operational_check: check)
  rescue Current::RoleAccessDenied
    raise
  rescue StandardError => error
    failure = error.is_a?(VerificationFailed) ? error :
      VerificationFailed.new(verification_failure_code(error), detail: "#{error.class}: #{error.message}")
    if actor && source_commit.to_s.match?(OperationalCheck::COMMIT_FORMAT)
      OperationalCheck.record!(
        workspace:, membership: actor, check_kind: "archive_verification", result: "failed",
        result_code: failure.result_code,
        evidence_digest: verification_evidence_digest(
          report: source_counts || {}, source_commit:, checked_at:, result_code: failure.result_code
        ),
        source_commit:, checked_at:, archive_format: FORMAT, counts: source_counts || {}
      )
    end
    raise failure
  ensure
    archive_io&.close!
    attachment_files&.each_value { |object| object.close! }
  end

  def self.import_archive(workspace:, actor:, archive:, attachment_files:, name:, slug:, imported_at:, verify:)
    attached_blobs = []
    validate_archive!(archive, workspace.organization)
    target = build_target(workspace.organization, name, slug)
    users = imported_users(archive.fetch("users"))
    tables = archive.fetch("tables")
    key_replacements = global_key_replacements(tables)
    attachment_objects = validate_attachment_objects!(attachment_files, tables)
    record_count = tables.sum { |_table, rows| rows.size }
    report = nil

    Workspace.transaction do
      target_id = Workspace.insert_all!([ target.attributes.except("id").merge(
        "created_at" => imported_at, "updated_at" => imported_at
      ) ], returning: %w[id]).first.fetch("id")
      target = Workspace.find(target_id)
      mappings = import_rows!(
        tables, source_workspace_id: archive.dig("workspace", "id"), target:, users:, key_replacements:
      )
      attached_blobs.concat(
        attach_objects!(target, attachment_objects, mappings.fetch("stored_attachments", {}))
      )
      target_actor = ensure_owner!(target, actor.user)
      AuditEvent.record!(
        action: "workspace.imported", source: :web, workspace: target, actor: actor.user, subject: target,
        metadata: { table_count: tables.size, record_count:, attachment_count: attachment_objects.size },
        occurred_at: imported_at
      )
      reconstructed_count = if verify || target.memory_records.exists?
        reconstruct_imported_memory!(target, target_actor, include_pending: verify)
      else
        0
      end
      report = verify_import!(
        archive:, target:, mappings:, users:, key_replacements:, reconstructed_count:
      ) if verify
      yield target, report if block_given?
    end
    ImportResult.new(workspace: target, report:)
  rescue StandardError
    attached_blobs.each { |blob| blob.service.delete(blob.key) }
    raise
  end
  private_class_method :import_archive

  def self.reconstruct_imported_memory!(workspace, membership, include_pending:)
    MemoryPortability.reconstruct_index!(workspace:, membership:, include_pending:)
  end
  private_class_method :reconstruct_imported_memory!

  def self.verify_import!(archive:, target:, mappings:, users:, key_replacements:, reconstructed_count:)
    tables = archive.fetch("tables")
    foreign_keys = foreign_key_columns(tables.keys)
    models = tables.keys.to_h { |table| [ table, model_for(table) ] }
    reverse_mappings = mappings.transform_values(&:invert)
    reverse_users = users.invert
    reverse_keys = key_replacements.invert
    table_digests = {}

    tables.each do |table, source_rows|
      table_mapping = mappings.fetch(table)
      raise VerificationFailed, "table_count_mismatch" unless
        table_mapping.size == source_rows.size && table_mapping.values.compact.uniq.size == source_rows.size

      target_rows = models.fetch(table).where(id: table_mapping.values).index_by(&:id)
      raise VerificationFailed, "partial_import" unless target_rows.size == source_rows.size

      expected_count = source_rows.size + verification_generated_row_count(table, tables)
      raise VerificationFailed, "table_count_mismatch" unless
        models.fetch(table).where(workspace_id: target.id).count == expected_count

      normalized_source = source_rows.map { |row| normalize_portable_types(row, models.fetch(table)) }
      normalized_target = source_rows.map do |source_row|
        imported = target_rows.fetch(table_mapping.fetch(source_row.fetch("id"))).attributes
        normalize_imported_row(
          imported, table:, source_row:, archive:, target:, foreign_keys:, models:,
          reverse_mappings:, reverse_users:, reverse_keys:
        )
      end
      source_digest = digest_rows(normalized_source)
      unless ActiveSupport::SecurityUtils.secure_compare(source_digest, digest_rows(normalized_target))
        changed_columns = normalized_source.zip(normalized_target).flat_map do |source, imported|
          source.keys.select { |column| canonical_value(source[column]) != canonical_value(imported[column]) }
        end.uniq.sort
        raise VerificationFailed.new("table_digest_mismatch", detail: "#{table}:#{changed_columns.join(',')}")
      end

      table_digests[table] = source_digest
    end

    verify_tenant_links!(target, tables.keys, foreign_keys)
    attachment_digests = verify_imported_attachments!(target, tables, mappings)
    memory_count = target.memory_records.current.available.count
    reconstructed = target.memory_records.current.available.joins(:memory_index_entry)
      .where(memory_index_entries: { status: :indexing }).count
    raise VerificationFailed, "memory_reconstruction_uncertain" unless
      reconstructed_count == memory_count && reconstructed == memory_count
    raise VerificationFailed, "memory_reconstruction_uncertain" if
      target.memory_records.current.available.joins(:memory_index_entry)
        .where.not(memory_index_entries: {
          external_document_id: nil, external_status: nil, indexed_at: nil, failure_code: nil
        }).exists?

    archive_counts(archive).merge(
      table_digests:, attachment_digests:, memory_reconstructed: reconstructed
    )
  end
  private_class_method :verify_import!

  def self.normalize_imported_row(row, table:, source_row:, archive:, target:, foreign_keys:, models:,
    reverse_mappings:, reverse_users:, reverse_keys:)
    attributes = normalize_portable_types(row, models.fetch(table))
    attributes["id"] = source_row.fetch("id")
    attributes["workspace_id"] = archive.dig("workspace", "id")
    foreign_keys.fetch(table).each do |column, key|
      value = attributes[column]
      next if value.nil?

      target_table = key.fetch(:table)
      attributes[column] = if target_table == "workspaces" && value == target.id
        archive.dig("workspace", "id")
      elsif target_table == "users"
        reverse_users.fetch(value)
      elsif reverse_mappings.key?(target_table)
        reverse_mappings.fetch(target_table).fetch(value)
      else
        value
      end
    end
    reverse_polymorphic_subject!(attributes, reverse_mappings, archive, target) if table == "audit_events"
    reverse_embedded_references!(attributes, table, reverse_mappings)
    reverse_archive_keys!(attributes, table, models.fetch(table), reverse_keys)
    if table == "memory_index_entries"
      attributes.merge!(PORTABLE_MEMORY_INDEX_STATE)
      attributes["updated_at"] = normalize_portable_types(source_row, models.fetch(table)).fetch("updated_at")
    end
    attributes
  end
  private_class_method :normalize_imported_row

  def self.verification_generated_row_count(table, tables)
    return 2 if table == "audit_events"
    return 0 unless table == "memory_index_entries"

    indexed_memory_ids = tables.fetch("memory_index_entries").pluck("memory_record_id").to_set
    superseded_memory_ids = tables.fetch("memory_records").pluck("supersedes_memory_record_id").compact.to_set
    tombstoned_memory_ids = tables.fetch("memory_tombstones").pluck("memory_record_id").to_set
    tables.fetch("memory_records").count do |row|
      memory_id = row.fetch("id")
      !indexed_memory_ids.include?(memory_id) && !superseded_memory_ids.include?(memory_id) &&
        !tombstoned_memory_ids.include?(memory_id)
    end
  end
  private_class_method :verification_generated_row_count

  def self.normalize_portable_types(row, model)
    row.each_with_object({}) do |(column, value), result|
      result[column] = model.type_for_attribute(column).deserialize(value)
    end
  end
  private_class_method :normalize_portable_types

  def self.reverse_polymorphic_subject!(attributes, reverse_mappings, archive, target)
    return unless attributes["subject_id"]

    target_table = attributes["subject_type"].to_s.safe_constantize&.table_name
    attributes["subject_id"] = if target_table == "workspaces" && attributes["subject_id"] == target.id
      archive.dig("workspace", "id")
    elsif reverse_mappings.key?(target_table)
      reverse_mappings.fetch(target_table).fetch(attributes["subject_id"])
    else
      attributes["subject_id"]
    end
  end
  private_class_method :reverse_polymorphic_subject!

  def self.reverse_embedded_references!(attributes, table, reverse_mappings)
    case table
    when "audit_events"
      attributes["metadata"] = attributes.fetch("metadata").each_with_object({}) do |(key, value), result|
        target_table = AUDIT_METADATA_ID_TABLES[key]
        result[key] = if target_table && reverse_mappings.fetch(target_table).key?(value)
          reverse_mappings.fetch(target_table).fetch(value)
        else
          value
        end
      end
    when "account_health_signals"
      attributes["evidence_refs"] = attributes.fetch("evidence_refs").map do |reference|
        target_table = HEALTH_EVIDENCE_TABLES.fetch(reference.fetch("kind"))
        reference.merge("id" => reverse_mappings.fetch(target_table).fetch(reference.fetch("id")))
      end
    when "customer_success_interventions"
      attributes["supporting_evidence"] = attributes.fetch("supporting_evidence").map do |item|
        item.merge("locator" => reverse_evidence_locator(item.fetch("locator"), reverse_mappings))
      end
    when "customer_success_intervention_outcome_reviews"
      %w[before_snapshot after_snapshot].each do |column|
        attributes[column] = reverse_intervention_snapshot(attributes.fetch(column), reverse_mappings)
      end
    when "governed_policy_previews"
      source, results = remap_governed_preview(
        attributes.fetch("source_snapshot"), attributes.fetch("results"), reverse_mappings
      )
      attributes["source_snapshot"] = source
      attributes["results"] = results
      attributes["evidence_digest"] = GovernedPolicyChange.digest(source)
      attributes["results_digest"] = GovernedPolicyChange.digest(results)
    end
  end
  private_class_method :reverse_embedded_references!

  def self.reverse_intervention_snapshot(snapshot, reverse_mappings)
    return snapshot if snapshot["retention"] == "expired"

    snapshot.merge(
      "assessment_id" => reverse_mappings.fetch("account_health_assessments").fetch(snapshot.fetch("assessment_id")),
      "scorecard_version_id" => reverse_mappings.fetch("health_scorecard_versions")
        .fetch(snapshot.fetch("scorecard_version_id")),
      "signals" => snapshot.fetch("signals").map do |signal|
        signal.merge(
          "id" => reverse_mappings.fetch("account_health_signals").fetch(signal.fetch("id")),
          "source_locator" => reverse_evidence_locator(signal.fetch("source_locator"), reverse_mappings),
          "evidence_refs" => signal.fetch("evidence_refs").map do |reference|
            target_table = HEALTH_EVIDENCE_TABLES.fetch(reference.fetch("kind"))
            reference.merge("id" => reverse_mappings.fetch(target_table).fetch(reference.fetch("id")))
          end
        )
      end
    )
  end
  private_class_method :reverse_intervention_snapshot

  def self.reverse_evidence_locator(locator, reverse_mappings)
    case locator
    when %r{\Ahealth://assessments/(\d+)(/signals/.+)\z}
      "health://assessments/#{reverse_mappings.fetch('account_health_assessments').fetch($1.to_i)}#{$2}"
    when %r{\Aconversation://(\d+)/messages/(\d+)\z}
      "conversation://#{reverse_mappings.fetch('conversations').fetch($1.to_i)}/messages/" \
        "#{reverse_mappings.fetch('conversation_messages').fetch($2.to_i)}"
    when %r{\Acase://(\d+)\z}
      "case://#{reverse_mappings.fetch('support_cases').fetch($1.to_i)}"
    when %r{\Aaccount://(\d+)(.*)\z}
      "account://#{reverse_mappings.fetch('accounts').fetch($1.to_i)}#{$2}"
    when %r{\Aretention-expired://customer-success-interventions/(\d+)/evidence/(\d+)\z}
      intervention_id = reverse_mappings.fetch("customer_success_interventions").fetch($1.to_i)
      "retention-expired://customer-success-interventions/#{intervention_id}/evidence/#{$2}"
    else
      locator
    end
  end
  private_class_method :reverse_evidence_locator

  def self.reverse_archive_keys!(attributes, table, model, reverse_keys)
    attributes.transform_values!.with_index do |value, index|
      column = attributes.keys.fetch(index)
      column_type = model.columns_hash.fetch(column).type
      if GLOBAL_KEY_COLUMNS[table] == column || REFERENCE_COLUMNS.include?(column) ||
          column_type.in?(%i[json jsonb])
        replace_key_references(value, reverse_keys)
      else
        value
      end
    end
  end
  private_class_method :reverse_archive_keys!

  def self.verify_tenant_links!(target, tables, foreign_keys)
    connection = ActiveRecord::Base.connection
    foreign_keys.each do |source_table, columns|
      columns.each do |column, key|
        target_table = key.fetch(:table)
        next unless target_table.in?(tables)

        source = connection.quote_table_name(source_table)
        referenced = connection.quote_table_name(target_table)
        foreign_column = connection.quote_column_name(column)
        invalid = connection.select_value(<<~SQL.squish).to_i
          SELECT COUNT(*)
          FROM #{source} source_rows
          LEFT JOIN #{referenced} target_rows ON target_rows.id = source_rows.#{foreign_column}
          WHERE source_rows.workspace_id = #{connection.quote(target.id)}
            AND source_rows.#{foreign_column} IS NOT NULL
            AND (target_rows.id IS NULL OR target_rows.workspace_id <> #{connection.quote(target.id)})
        SQL
        raise VerificationFailed, "tenant_isolation_failed" if invalid.positive?
      end
    end
  end
  private_class_method :verify_tenant_links!

  def self.verify_imported_attachments!(target, tables, mappings)
    source_rows = tables.fetch("stored_attachments").index_by { |row| row.fetch("id") }
    mappings.fetch("stored_attachments").sort.map do |source_id, target_id|
      source = source_rows.fetch(source_id)
      attachment = target.stored_attachments.find(target_id)
      digest = Digest::SHA256.hexdigest(attachment.download_verified!)
      raise VerificationFailed, "attachment_mismatch" unless
        attachment.byte_size == source.fetch("byte_size") &&
          ActiveSupport::SecurityUtils.secure_compare(digest, source.fetch("content_sha256"))

      [ source_id, digest ]
    end
  rescue ActiveStorage::IntegrityError, ActiveStorage::FileNotFoundError
    raise VerificationFailed, "attachment_mismatch"
  end
  private_class_method :verify_imported_attachments!

  def self.archive_counts(archive)
    tables = archive.fetch("tables")
    {
      table: tables.size,
      record: tables.sum { |_table, rows| rows.size },
      attachment: tables.fetch("stored_attachments").size,
      memory: tables.fetch("memory_records").size
    }
  end
  private_class_method :archive_counts

  def self.digest_rows(rows)
    Digest::SHA256.hexdigest(JSON.generate(canonical_value(rows)))
  end
  private_class_method :digest_rows

  def self.canonical_value(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [ key, canonical_value(value.fetch(key)) ] }
    when Array then value.map { |item| canonical_value(item) }
    when Time, ActiveSupport::TimeWithZone then value.iso8601(6)
    when Date, DateTime then value.iso8601
    when BigDecimal then value.to_s("F")
    else value
    end
  end
  private_class_method :canonical_value

  def self.verification_evidence_digest(report:, source_commit:, checked_at:, result_code:)
    Digest::SHA256.hexdigest(JSON.generate(canonical_value(
      report.merge(source_commit:, checked_at: checked_at.iso8601(6), result_code:)
    )))
  end
  private_class_method :verification_evidence_digest

  def self.verification_failure_code(error)
    return "attachment_mismatch" if error.is_a?(ActiveStorage::IntegrityError) ||
      error.is_a?(ActiveStorage::FileNotFoundError)
    return "partial_import" if error.is_a?(ActiveRecord::StatementInvalid)

    message = error.message
    return "cross_organization_archive" if message.include?("another organization")
    return "missing_user" if message.include?("Create and verify local users")
    return "unsupported_schema" if message.match?(/format is not supported|tables do not match this release/)
    return "attachment_mismatch" if message.match?(/attachment.*(?:digest|size|object)/i)

    "archive_round_trip_failed"
  end
  private_class_method :verification_failure_code

  def self.workspace_tables
    connection = ActiveRecord::Base.connection
    connection.select_values(<<~SQL.squish)
      SELECT table_name
      FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'workspace_id'
      ORDER BY table_name
    SQL
  end
  private_class_method :workspace_tables

  def self.parse_archive(io)
    archive = nil
    attachment_metadata = nil
    objects = {}
    gzip = Zlib::GzipReader.new(BoundedReader.new(io, MAX_ARCHIVE_BYTES))
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        if entry.full_name == "manifest.json"
          raise InvalidArchive, "Workspace archive has a duplicate manifest." if archive
          raise InvalidArchive, "Workspace archive manifest exceeds the 64 MiB expanded limit." if entry.size > MAX_UNCOMPRESSED_BYTES
          archive = JSON.parse(entry.read)
          attachment_metadata = attachment_metadata!(archive)
        elsif (match = entry.full_name.match(%r{\Aattachment_objects/(\d+)\z}))
          raise InvalidArchive, "Workspace archive manifest must be the first entry." unless archive
          id = Integer(match[1])
          raise InvalidArchive, "Workspace archive has a duplicate attachment object." if objects.key?(id)
          row = attachment_metadata.fetch(id) { raise InvalidArchive, "Workspace archive attachment object has no metadata." }
          expected_size = row.fetch("byte_size")
          raise InvalidArchive, "Workspace archive attachment size does not match." unless entry.size == expected_size
          file = Tempfile.new([ "workspace-attachment", ".object" ], binmode: true)
          objects[id] = file
          IO.copy_stream(entry, file)
          file.rewind
        else
          raise InvalidArchive, "Workspace archive contains an unexpected entry."
        end
      end
    end
    raise InvalidArchive, "Workspace archive has no manifest." unless archive
    [ archive, objects ]
  rescue StandardError
    objects&.each_value { |object| object.close! }
    raise
  end
  private_class_method :parse_archive

  def self.attachment_metadata!(archive)
    rows = archive.fetch("tables").fetch("stored_attachments")
    raise InvalidArchive, "Workspace archive attachment metadata is invalid." unless rows.is_a?(Array)

    result = {}
    total = 0
    rows.each do |row|
      id = row.fetch("id")
      size = row.fetch("byte_size")
      unless id.is_a?(Integer) && size.is_a?(Integer) && size.in?(1..StoredAttachment::MAX_BYTES) && !result.key?(id)
        raise InvalidArchive, "Workspace archive attachment metadata is invalid."
      end
      total += size
      raise InvalidArchive, "Workspace attachments exceed the 50 MiB archive limit." if total > MAX_ATTACHMENT_BYTES
      result[id] = row
    end
    result
  rescue KeyError
    raise InvalidArchive, "Workspace archive attachment metadata is invalid."
  end
  private_class_method :attachment_metadata!

  def self.validate_archive!(archive, organization)
    raise InvalidArchive, "Workspace archive fields do not match this format." unless archive.is_a?(Hash) && archive.keys.sort == ARCHIVE_KEYS.sort
    raise InvalidArchive, "Workspace archive format is not supported." unless archive.fetch("format") == FORMAT
    raise InvalidArchive, "Workspace archive belongs to another organization." unless archive.dig("organization", "slug") == organization.slug
    raise InvalidArchive, "Workspace archive organization fields are invalid." unless archive.fetch("organization").keys.sort == %w[name slug]
    raise InvalidArchive, "Workspace archive tables do not match this release." unless archive.fetch("tables").keys == workspace_tables
    raise InvalidArchive, "Workspace archive user list is invalid." unless archive.fetch("users").is_a?(Array)
    workspace_columns = ActiveRecord::Base.connection.columns("workspaces").map(&:name).sort
    raise InvalidArchive, "Workspace archive identity is invalid." unless archive.fetch("workspace").keys.sort == workspace_columns
    archive.fetch("tables").each do |table, rows|
      columns = ActiveRecord::Base.connection.columns(table).map(&:name).sort
      raise InvalidArchive, "#{table} rows are invalid." unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row.keys.sort == columns }
      raise InvalidArchive, "#{table} contains another workspace." unless rows.all? { |row| row.fetch("workspace_id") == archive.dig("workspace", "id") }
    end
    archive.fetch("users").each do |user|
      raise InvalidArchive, "Workspace archive user fields are invalid." unless user.is_a?(Hash) && user.keys.sort == USER_ATTRIBUTES.sort
    end
  end
  private_class_method :validate_archive!

  def self.build_target(organization, name, slug)
    target = organization.workspaces.new(name: name.to_s, slug: slug.to_s, runner_key: SecureRandom.uuid)
    raise ActiveRecord::RecordInvalid, target unless target.valid?

    target
  end
  private_class_method :build_target

  def self.imported_users(rows)
    emails = rows.map { |row| row.fetch("email_address").to_s.downcase }
    raise InvalidArchive, "Workspace archive contains duplicate users." unless emails.uniq.size == emails.size

    users = User.where(email_address: emails).where.not(verified_at: nil).index_by { |user| user.email_address.downcase }
    missing = emails - users.keys
    raise InvalidArchive, "Create and verify local users before import: #{missing.join(', ')}." if missing.any?

    rows.to_h { |row| [ row.fetch("id"), users.fetch(row.fetch("email_address").downcase).id ] }
  end
  private_class_method :imported_users

  def self.global_key_replacements(tables)
    GLOBAL_KEY_COLUMNS.each_with_object({}) do |(table, column), replacements|
      tables.fetch(table).each do |row|
        old_value = row[column]
        replacements[old_value] = SecureRandom.uuid if old_value.present?
      end
    end
  end
  private_class_method :global_key_replacements

  def self.validate_attachment_objects!(objects, tables)
    attachment_rows = attachment_metadata!({ "tables" => tables })
    raise InvalidArchive, "Workspace archive attachment objects do not match metadata." unless objects.keys.to_set == attachment_rows.keys.to_set

    objects.map do |id, file|
      row = attachment_rows.fetch(id)
      digest = Digest::SHA256.file(file.path).hexdigest
      raise InvalidArchive, "Workspace archive attachment digest does not match." unless
        ActiveSupport::SecurityUtils.secure_compare(digest, row.fetch("content_sha256"))
      raise InvalidArchive, "Workspace archive attachment size does not match." unless file.size == row.fetch("byte_size")

      [ row, file ]
    end
  rescue KeyError
    raise InvalidArchive, "Workspace archive attachment is invalid."
  end
  private_class_method :validate_attachment_objects!

  def self.import_rows!(tables, source_workspace_id:, target:, users:, key_replacements:)
    connection = ActiveRecord::Base.connection
    foreign_keys = foreign_key_columns(tables.keys)
    mappings = tables.to_h { |table, rows| [ table, rows.to_h { |row| [ row.fetch("id"), nil ] } ] }
    order = insertion_order(tables.keys, foreign_keys)
    models = tables.keys.to_h { |table| [ table, model_for(table) ] }
    deferred = []
    polymorphic = []

    tables.keys.each { |table| connection.execute("ALTER TABLE #{connection.quote_table_name(table)} DISABLE TRIGGER USER") }
    order.each do |table|
      tables.fetch(table).each do |row|
        old_id = row.fetch("id")
        attributes = row.except("id")
        attributes = remap_keys(attributes, table, models.fetch(table), key_replacements)
        attributes = attributes.merge(PORTABLE_MEMORY_INDEX_STATE) if table == "memory_index_entries"
        attributes["workspace_id"] = target.id
        foreign_keys.fetch(table, {}).each do |column, key|
          old_value = row[column]
          next if old_value.nil?

          target_table = key.fetch(:table)
          if key.fetch(:nullable) && target_table.in?(tables.keys) && mappings.fetch(target_table)[old_value].nil?
            attributes[column] = nil
            deferred << [ table, old_id, column, target_table, old_value ]
          else
            attributes[column] = foreign_value(
              target_table, old_value, source_workspace_id:, target:, users:, mappings:
            )
          end
        end
        if table == "audit_events" && row["subject_id"]
          attributes["subject_id"] = nil
          polymorphic << [ table, old_id, "subject_id", row["subject_type"], row["subject_id"] ]
        end
        inserted = models.fetch(table).insert_all!([ attributes ], returning: %w[id]).first
        mappings.fetch(table)[old_id] = inserted.fetch("id")
      end
    end
    deferred.each do |table, old_id, column, target_table, old_target_id|
      models.fetch(table).where(id: mappings.fetch(table).fetch(old_id))
        .update_all(column => mappings.fetch(target_table).fetch(old_target_id))
    end
    polymorphic.each do |table, old_id, column, type, old_target_id|
      target_table = type.to_s.safe_constantize&.table_name
      mapped_id = if target_table == "workspaces" && old_target_id == source_workspace_id
        target.id
      elsif mappings.key?(target_table) && mappings.fetch(target_table).key?(old_target_id)
        mappings.fetch(target_table).fetch(old_target_id)
      end
      next unless mapped_id

      models.fetch(table).where(id: mappings.fetch(table).fetch(old_id))
        .update_all(column => mapped_id)
    end
    tables.fetch("audit_events").each do |row|
      metadata = row.fetch("metadata")
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      remapped_metadata = metadata.each_with_object({}) do |(key, value), result|
        target_table = AUDIT_METADATA_ID_TABLES[key]
        result[key] = if target_table && mappings.fetch(target_table).key?(value)
          mappings.fetch(target_table).fetch(value)
        else
          value
        end
      end
      models.fetch("audit_events").where(id: mappings.fetch("audit_events").fetch(row.fetch("id")))
        .update_all(metadata: remapped_metadata)
    end
    tables.fetch("account_health_signals").each do |row|
      references = row.fetch("evidence_refs")
      references = JSON.parse(references) if references.is_a?(String)
      next if references.empty?

      remapped_references = references.map do |reference|
        target_table = HEALTH_EVIDENCE_TABLES.fetch(reference.fetch("kind"))
        reference.merge("id" => mappings.fetch(target_table).fetch(reference.fetch("id")))
      end
      models.fetch("account_health_signals")
        .where(id: mappings.fetch("account_health_signals").fetch(row.fetch("id")))
        .update_all(evidence_refs: remapped_references)
    end
    remap_intervention_records!(tables, mappings, models)
    remap_governed_policy_previews!(tables, mappings, models)
    connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    tables.keys.each { |table| connection.execute("ALTER TABLE #{connection.quote_table_name(table)} ENABLE TRIGGER USER") }
    mappings
  end
  private_class_method :import_rows!

  def self.remap_intervention_records!(tables, mappings, models)
    tables.fetch("customer_success_interventions").each do |row|
      evidence = row.fetch("supporting_evidence")
      evidence = JSON.parse(evidence) if evidence.is_a?(String)
      remapped = evidence.map do |item|
        item.merge("locator" => remap_evidence_locator(item.fetch("locator"), mappings))
      end
      models.fetch("customer_success_interventions")
        .where(id: mappings.fetch("customer_success_interventions").fetch(row.fetch("id")))
        .update_all(supporting_evidence: remapped)
    end

    tables.fetch("customer_success_intervention_outcome_reviews").each do |row|
      attributes = %w[before_snapshot after_snapshot].to_h do |column|
        snapshot = row.fetch(column)
        snapshot = JSON.parse(snapshot) if snapshot.is_a?(String)
        [ column, remap_intervention_snapshot(snapshot, mappings) ]
      end
      models.fetch("customer_success_intervention_outcome_reviews")
        .where(id: mappings.fetch("customer_success_intervention_outcome_reviews").fetch(row.fetch("id")))
        .update_all(attributes)
    end
  end
  private_class_method :remap_intervention_records!

  def self.remap_governed_policy_previews!(tables, mappings, models)
    tables.fetch("governed_policy_previews").each do |row|
      source = row.fetch("source_snapshot")
      source = JSON.parse(source) if source.is_a?(String)
      results = row.fetch("results")
      results = JSON.parse(results) if results.is_a?(String)
      source, results = remap_governed_preview(source, results, mappings)
      models.fetch("governed_policy_previews")
        .where(id: mappings.fetch("governed_policy_previews").fetch(row.fetch("id")))
        .update_all(
          source_snapshot: source, results:,
          evidence_digest: GovernedPolicyChange.digest(source),
          results_digest: GovernedPolicyChange.digest(results)
        )
    end
  end
  private_class_method :remap_governed_policy_previews!

  def self.remap_governed_preview(source, results, mappings)
    return [ source, results ] if source["retention"] == "expired"

    remapped_source = source.deep_dup
    proposal = remapped_source.fetch("proposal")
    proposal["id"] = mapped_id(mappings, "governed_policy_proposals", proposal.fetch("id"))
    proposal["family_current_version_id"] = mapped_id(
      mappings, "resolution_contract_versions", proposal.fetch("family_current_version_id")
    )
    proposal["profile_current_version_id"] = mapped_id(
      mappings, "agent_profile_versions", proposal.fetch("profile_current_version_id")
    )
    %w[prior_contract candidate_contract].each do |key|
      proposal.fetch(key)["id"] = mapped_id(
        mappings, "resolution_contract_versions", proposal.fetch(key).fetch("id")
      )
    end
    %w[prior_profile candidate_profile].each do |key|
      proposal.fetch(key)["id"] = mapped_id(
        mappings, "agent_profile_versions", proposal.fetch(key).fetch("id")
      )
    end
    remapped_source.fetch("subjects").each do |subject|
      subject["id"] = mapped_subject_id(mappings, subject.fetch("kind"), subject.fetch("id"))
    end
    remapped_source.fetch("memberships").each do |membership|
      membership["id"] = mapped_id(mappings, "memberships", membership.fetch("id"))
    end
    remapped_source.fetch("runtime_installations").each do |runtime|
      runtime["id"] = mapped_id(mappings, "runtime_installations", runtime.fetch("id"))
    end
    retained = remapped_source.fetch("retained_records")
    retained.fetch("tasks").each do |task|
      task["id"] = mapped_id(mappings, "crew_tasks", task.fetch("id"))
      task["support_case_id"] = mapped_id(mappings, "support_cases", task["support_case_id"])
      task["account_id"] = mapped_id(mappings, "accounts", task["account_id"])
      task["resolved_account_id"] = mapped_id(mappings, "accounts", task["resolved_account_id"])
      task["agent_profile_id"] = mapped_id(mappings, "agent_profiles", task["agent_profile_id"])
    end
    retained.fetch("artifacts").each do |artifact|
      artifact["id"] = mapped_id(mappings, "crew_artifacts", artifact.fetch("id"))
      artifact["crew_task_id"] = mapped_id(mappings, "crew_tasks", artifact.fetch("crew_task_id"))
      artifact["resolution_contract_version_id"] = mapped_id(
        mappings, "resolution_contract_versions", artifact["resolution_contract_version_id"]
      )
      remap_material_claim_locators!(artifact.fetch("material_claims"), mappings)
    end
    retained.fetch("runs").each do |run|
      run["id"] = mapped_id(mappings, "execution_runs", run.fetch("id"))
      run["crew_task_id"] = mapped_id(mappings, "crew_tasks", run.fetch("crew_task_id"))
      run["agent_profile_version_id"] = mapped_id(
        mappings, "agent_profile_versions", run.fetch("agent_profile_version_id")
      )
      run["runtime_installation_id"] = mapped_id(
        mappings, "runtime_installations", run.fetch("runtime_installation_id")
      )
    end
    remapped_source.fetch("scope_publications").each do |publication|
      publication[0] = mapped_id(mappings, "governed_policy_publications", publication.fetch(0))
      publication[2] = mapped_id(mappings, "resolution_contract_versions", publication.fetch(2))
      publication[3] = mapped_id(mappings, "agent_profile_versions", publication.fetch(3))
    end

    remapped_results = results.deep_dup
    remapped_results.each do |result|
      result["subject_id"] = mapped_subject_id(
        mappings, result.fetch("subject_kind"), result.fetch("subject_id")
      )
      result.fetch("facts").each do |fact|
        case fact.fetch("key")
        when "subject.id"
          fact["value"] = mapped_subject_id(mappings, result.fetch("subject_kind"), fact.fetch("value"))
        when "runtime.installations"
          fact.fetch("value").each do |runtime|
            runtime["id"] = mapped_id(mappings, "runtime_installations", runtime.fetch("id"))
          end
        when "evidence.records"
          fact.fetch("value").each do |evidence|
            evidence["locator"] = remap_evidence_locator(evidence.fetch("locator"), mappings)
          end
        end
      end
    end
    [ remapped_source, remapped_results ]
  end
  private_class_method :remap_governed_preview

  def self.remap_material_claim_locators!(claims, mappings)
    claims.each do |claim|
      claim.fetch("evidence").each do |evidence|
        evidence["locator"] = remap_evidence_locator(evidence.fetch("locator"), mappings)
      end
    end
  end
  private_class_method :remap_material_claim_locators!

  def self.mapped_subject_id(mappings, kind, id)
    table = {
      "support_case" => "support_cases", "account" => "accounts", "agent_profile" => "agent_profiles"
    }.fetch(kind)
    mapped_id(mappings, table, id)
  end
  private_class_method :mapped_subject_id

  def self.mapped_id(mappings, table, id)
    return if id.nil?

    mappings.fetch(table).fetch(id)
  end
  private_class_method :mapped_id

  def self.remap_intervention_snapshot(snapshot, mappings)
    return snapshot if snapshot["retention"] == "expired"

    snapshot.merge(
      "assessment_id" => mappings.fetch("account_health_assessments").fetch(snapshot.fetch("assessment_id")),
      "scorecard_version_id" => mappings.fetch("health_scorecard_versions").fetch(snapshot.fetch("scorecard_version_id")),
      "signals" => snapshot.fetch("signals").map do |signal|
        signal.merge(
          "id" => mappings.fetch("account_health_signals").fetch(signal.fetch("id")),
          "source_locator" => remap_evidence_locator(signal.fetch("source_locator"), mappings),
          "evidence_refs" => signal.fetch("evidence_refs").map do |reference|
            table = HEALTH_EVIDENCE_TABLES.fetch(reference.fetch("kind"))
            reference.merge("id" => mappings.fetch(table).fetch(reference.fetch("id")))
          end
        )
      end
    )
  end
  private_class_method :remap_intervention_snapshot

  def self.remap_evidence_locator(locator, mappings)
    case locator
    when %r{\Ahealth://assessments/(\d+)(/signals/.+)\z}
      "health://assessments/#{mappings.fetch('account_health_assessments').fetch($1.to_i)}#{$2}"
    when %r{\Aconversation://(\d+)/messages/(\d+)\z}
      "conversation://#{mappings.fetch('conversations').fetch($1.to_i)}/messages/#{mappings.fetch('conversation_messages').fetch($2.to_i)}"
    when %r{\Acase://(\d+)\z}
      "case://#{mappings.fetch('support_cases').fetch($1.to_i)}"
    when %r{\Aaccount://(\d+)(.*)\z}
      "account://#{mappings.fetch('accounts').fetch($1.to_i)}#{$2}"
    when %r{\Aretention-expired://customer-success-interventions/(\d+)/evidence/(\d+)\z}
      intervention_id = mappings.fetch("customer_success_interventions").fetch($1.to_i)
      "retention-expired://customer-success-interventions/#{intervention_id}/evidence/#{$2}"
    else
      locator
    end
  end
  private_class_method :remap_evidence_locator

  def self.foreign_key_columns(tables)
    rows = ActiveRecord::Base.connection.select_all(<<~SQL)
      SELECT source.relname AS source_table, source_column.attname AS source_column,
        target.relname AS target_table, source_column.attnotnull AS required
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
    tables.to_h { |table| [ table, {} ] }.tap do |result|
      rows.each do |row|
        next unless result.key?(row.fetch("source_table"))

        source_table = row.fetch("source_table")
        source_column = row.fetch("source_column")
        result.fetch(row.fetch("source_table"))[row.fetch("source_column")] = {
          table: row.fetch("target_table"),
          nullable: !row.fetch("required") && !NON_DEFERRED_FOREIGN_KEYS.include?("#{source_table}.#{source_column}")
        }
      end
      result.each do |table, keys|
        columns = ActiveRecord::Base.connection.columns(table).index_by(&:name)
        MAPPED_REFERENCE_COLUMNS.each do |column, target_table|
          next unless columns.key?(column)

          keys[column] = { table: target_table, nullable: columns.fetch(column).null }
        end
      end
    end
  end
  private_class_method :foreign_key_columns

  def self.insertion_order(tables, foreign_keys)
    dependencies = tables.to_h do |table|
      required = foreign_keys.fetch(table).values.filter_map do |key|
        key.fetch(:table) if !key.fetch(:nullable) && key.fetch(:table).in?(tables) && key.fetch(:table) != table
      end
      [ table, required.uniq ]
    end
    result = []
    until dependencies.empty?
      ready = dependencies.filter_map { |table, needs| table if (needs - result).empty? }.sort
      raise InvalidArchive, "Workspace archive has an unsupported required-reference cycle." if ready.empty?

      result.concat(ready)
      dependencies.except!(*ready)
    end
    result
  end
  private_class_method :insertion_order

  def self.model_for(table)
    Class.new(ApplicationRecord) do
      self.table_name = table
      self.inheritance_column = :_type_disabled
    end
  end
  private_class_method :model_for

  def self.foreign_value(table, old_value, source_workspace_id:, target:, users:, mappings:)
    return target.id if table == "workspaces" && old_value == source_workspace_id
    return target.organization_id if table == "organizations"
    return users.fetch(old_value) if table == "users"
    return mappings.fetch(table).fetch(old_value) if mappings.key?(table)

    old_value
  end
  private_class_method :foreign_value

  def self.remap_keys(attributes, table, model, replacements)
    attributes.each_with_object({}) do |(column, value), remapped|
      column_type = model.columns_hash.fetch(column).type
      value = JSON.parse(value) if column_type.in?(%i[json jsonb]) && value.is_a?(String)
      if GLOBAL_KEY_COLUMNS[table] == column
        remapped[column] = replacements.fetch(value, value)
      elsif REFERENCE_COLUMNS.include?(column) || column_type.in?(%i[json jsonb])
        remapped[column] = replace_key_references(value, replacements)
      else
        remapped[column] = value
      end
    end
  end
  private_class_method :remap_keys

  def self.replace_key_references(value, replacements)
    case value
    when Hash then value.transform_values { |nested| replace_key_references(nested, replacements) }
    when Array then value.map { |nested| replace_key_references(nested, replacements) }
    when String
      replacements.reduce(value) { |text, (old_key, new_key)| text.gsub(old_key, new_key) }
    else value
    end
  end
  private_class_method :replace_key_references

  def self.attach_objects!(target, objects, attachment_mapping)
    blobs = []
    objects.each do |row, file|
      attachment = target.stored_attachments.find(attachment_mapping.fetch(row.fetch("id")))
      file.rewind
      blob = ActiveStorage::Blob.create_and_upload!(
        io: file, filename: row.fetch("filename"), content_type: row.fetch("detected_content_type"),
        identify: false
      )
      blobs << blob
      attachment.file.attach(blob)
    end
    blobs
  rescue StandardError
    blobs.each { |blob| blob.service.delete(blob.key) }
    raise
  end
  private_class_method :attach_objects!

  def self.ensure_owner!(workspace, user)
    membership = workspace.memberships.find_by(user:)
    return membership.tap { |record| record.update!(role: :owner) } if membership

    workspace.memberships.create!(user:, role: :owner)
  end
  private_class_method :ensure_owner!

  def self.workspace_rows(table, workspace_id)
    connection = ActiveRecord::Base.connection
    quoted_table = connection.quote_table_name(table)
    rows = connection.select_all(
      "SELECT * FROM #{quoted_table} WHERE workspace_id = #{connection.quote(workspace_id)} ORDER BY id"
    ).to_a
    return rows unless table == "memory_index_entries"

    rows.map { |row| row.merge(PORTABLE_MEMORY_INDEX_STATE) }
  end
  private_class_method :workspace_rows

  def self.referenced_users(tables)
    connection = ActiveRecord::Base.connection
    ids = tables.flat_map do |table, rows|
      user_columns = connection.foreign_keys(table).select { |key| key.to_table == "users" }.map(&:column)
      rows.flat_map { |row| user_columns.filter_map { |column| row[column] } }
    end.uniq
    User.where(id: ids).order(:id).map { |user| user.attributes.slice(*USER_ATTRIBUTES) }
  end
  private_class_method :referenced_users

  class BoundedReader
    def initialize(io, maximum)
      @io = io
      @remaining = maximum
    end

    def read(length = nil, output = nil)
      requested = [ length || @remaining + 1, @remaining + 1 ].min
      consume(@io.read(requested, output))
    end

    def readpartial(length, output = nil)
      consume(@io.readpartial([ length, @remaining + 1 ].min, output))
    end

    private
      def consume(data)
        return data unless data

        @remaining -= data.bytesize
        raise InvalidArchive, "Workspace archive exceeds the 60 MiB limit." if @remaining.negative?

        data
      end
  end
  private_constant :BoundedReader
end
