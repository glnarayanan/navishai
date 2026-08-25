require "base64"
require "stringio"
require "zlib"

class WorkspacePortability
  FORMAT = "navishai-workspace-v1"
  USER_ATTRIBUTES = %w[id email_address verified_at].freeze

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
