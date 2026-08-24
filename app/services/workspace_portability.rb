require "base64"
require "digest"
require "json"
require "set"
require "stringio"
require "zlib"

class WorkspacePortability
  FORMAT = "navishai-workspace-v1"
  MAX_COMPRESSED_BYTES = 8.megabytes
  MAX_UNCOMPRESSED_BYTES = 64.megabytes
  USER_ATTRIBUTES = %w[id email_address verified_at].freeze
  ARCHIVE_KEYS = %w[format exported_at organization workspace users tables attachment_objects].freeze
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

  class InvalidArchive < StandardError; end

  def self.export(workspace:, membership:, exported_at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.owner?

    archive = nil
    record_count = 0
    attachment_count = 0
    Workspace.transaction(isolation: :repeatable_read) do
      tables = workspace_tables.to_h do |table|
        rows = workspace_rows(table, workspace.id)
        record_count += rows.size
        [ table, rows ]
      end
      users = referenced_users(tables)
      attachments = workspace.stored_attachments.includes(file_attachment: :blob).order(:id).map do |attachment|
        next unless attachment.file.attached?

        attachment_count += 1
        {
          "stored_attachment_id" => attachment.id,
          "content_sha256" => attachment.content_sha256,
          "data" => Base64.strict_encode64(attachment.download_verified!)
        }
      end.compact
      archive = {
        "format" => FORMAT,
        "exported_at" => exported_at.iso8601(6),
        "organization" => workspace.organization.attributes.slice("name", "slug"),
        "workspace" => workspace.attributes,
        "users" => users,
        "tables" => tables,
        "attachment_objects" => attachments
      }
      AuditEvent.record!(
        action: "workspace.exported", source: :web, workspace:, actor: actor.user, subject: workspace,
        metadata: { table_count: tables.size, record_count:, attachment_count: }, occurred_at: exported_at
      )
    end
    gzip(JSON.generate(archive))
  end

  def self.import(workspace:, membership:, archive_io:, name:, slug:, imported_at: Time.current)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.owner?

    archive = parse_archive(archive_io)
    validate_archive!(archive, workspace.organization)
    target = build_target(workspace.organization, name, slug)
    users = imported_users(archive.fetch("users"))
    tables = archive.fetch("tables")
    key_replacements = global_key_replacements(tables)
    attachment_objects = validate_attachment_objects!(archive.fetch("attachment_objects"), tables)
    record_count = tables.sum { |_table, rows| rows.size }

    Workspace.transaction do
      target_id = Workspace.insert_all!([ target.attributes.except("id").merge(
        "created_at" => imported_at, "updated_at" => imported_at
      ) ], returning: %w[id]).first.fetch("id")
      target = Workspace.find(target_id)
      mappings = import_rows!(tables, source_workspace_id: archive.dig("workspace", "id"), target:, users:,
        key_replacements:)
      attach_objects!(target, attachment_objects, mappings.fetch("stored_attachments", {}))
      target_actor = ensure_owner!(target, actor.user)
      AuditEvent.record!(
        action: "workspace.imported", source: :web, workspace: target, actor: actor.user, subject: target,
        metadata: { table_count: tables.size, record_count:, attachment_count: attachment_objects.size },
        occurred_at: imported_at
      )
      reset_memory_index!(target)
      MemoryPortability.reconstruct_index!(workspace: target, membership: target_actor) if target.memory_records.exists?
    end
    target
  rescue ActiveRecord::StatementInvalid
    raise InvalidArchive, "Workspace archive data does not satisfy this release."
  rescue Zlib::GzipFile::Error, JSON::ParserError, KeyError, TypeError, ArgumentError,
    ActiveRecord::RecordInvalid => error
    raise InvalidArchive, "Workspace archive is invalid: #{error.message}"
  end

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
    compressed = io.read(MAX_COMPRESSED_BYTES + 1).to_s.b
    raise InvalidArchive, "Workspace archive exceeds the 8 MiB compressed limit." if compressed.bytesize > MAX_COMPRESSED_BYTES

    reader = Zlib::GzipReader.new(StringIO.new(compressed))
    json = reader.read(MAX_UNCOMPRESSED_BYTES + 1)
    raise InvalidArchive, "Workspace archive exceeds the 64 MiB expanded limit." if json.bytesize > MAX_UNCOMPRESSED_BYTES

    JSON.parse(json)
  ensure
    reader&.close
  end
  private_class_method :parse_archive

  def self.validate_archive!(archive, organization)
    raise InvalidArchive, "Workspace archive fields do not match this format." unless archive.is_a?(Hash) && archive.keys.sort == ARCHIVE_KEYS.sort
    raise InvalidArchive, "Workspace archive format is not supported." unless archive.fetch("format") == FORMAT
    raise InvalidArchive, "Workspace archive belongs to another organization." unless archive.dig("organization", "slug") == organization.slug
    raise InvalidArchive, "Workspace archive organization fields are invalid." unless archive.fetch("organization").keys.sort == %w[name slug]
    raise InvalidArchive, "Workspace archive tables do not match this release." unless archive.fetch("tables").keys == workspace_tables
    raise InvalidArchive, "Workspace archive user list is invalid." unless archive.fetch("users").is_a?(Array)
    raise InvalidArchive, "Workspace archive attachment list is invalid." unless archive.fetch("attachment_objects").is_a?(Array)

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
    attachment_rows = tables.fetch("stored_attachments").index_by { |row| row.fetch("id") }
    seen = Set.new
    objects.map do |object|
      unless object.is_a?(Hash) && object.keys.sort == %w[content_sha256 data stored_attachment_id] &&
          seen.add?(object.fetch("stored_attachment_id"))
        raise InvalidArchive, "Workspace archive attachment fields are invalid."
      end
      row = attachment_rows.fetch(object.fetch("stored_attachment_id"))
      bytes = Base64.strict_decode64(object.fetch("data"))
      raise InvalidArchive, "Workspace archive attachment digest does not match." unless
        ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(bytes), row.fetch("content_sha256"))

      [ row, bytes ]
    end
  rescue KeyError, ArgumentError
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
    connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
    tables.keys.each { |table| connection.execute("ALTER TABLE #{connection.quote_table_name(table)} ENABLE TRIGGER USER") }
    mappings
  end
  private_class_method :import_rows!

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

        result.fetch(row.fetch("source_table"))[row.fetch("source_column")] = {
          table: row.fetch("target_table"), nullable: !row.fetch("required")
        }
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
    objects.each do |row, bytes|
      attachment = target.stored_attachments.find(attachment_mapping.fetch(row.fetch("id")))
      attachment.file.attach(
        io: StringIO.new(bytes), filename: row.fetch("filename"), content_type: row.fetch("detected_content_type")
      )
    end
  end
  private_class_method :attach_objects!

  def self.ensure_owner!(workspace, user)
    membership = workspace.memberships.find_by(user:)
    return membership.tap { |record| record.update!(role: :owner) } if membership

    workspace.memberships.create!(user:, role: :owner)
  end
  private_class_method :ensure_owner!

  def self.reset_memory_index!(workspace)
    workspace.memory_index_entries.update_all(
      status: MemoryIndexEntry.statuses.fetch("pending"), attempt_count: 0, external_document_id: nil,
      external_status: nil, failure_code: nil, last_attempted_at: nil, indexed_at: nil
    )
  end
  private_class_method :reset_memory_index!

  def self.workspace_rows(table, workspace_id)
    connection = ActiveRecord::Base.connection
    quoted_table = connection.quote_table_name(table)
    connection.select_all(
      "SELECT * FROM #{quoted_table} WHERE workspace_id = #{connection.quote(workspace_id)} ORDER BY id"
    ).to_a
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

  def self.gzip(json)
    output = StringIO.new
    Zlib::GzipWriter.wrap(output) { |gzip| gzip.write(json) }
    output.string
  end
  private_class_method :gzip
end
