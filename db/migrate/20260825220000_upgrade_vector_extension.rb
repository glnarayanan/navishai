class UpgradeVectorExtension < ActiveRecord::Migration[8.1]
  FROM_VERSION = "0.8.1"
  TO_VERSION = "0.8.6"

  def up
    current_version = select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
    return if current_version == TO_VERSION

    unless current_version == FROM_VERSION
      raise ActiveRecord::MigrationError,
        "Unsupported pgvector version #{current_version || 'none'}; expected #{FROM_VERSION} or #{TO_VERSION}"
    end

    execute "ALTER EXTENSION vector UPDATE TO '#{TO_VERSION}'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "pgvector #{TO_VERSION} cannot be downgraded safely; restore the verified pre-upgrade backup"
  end
end
