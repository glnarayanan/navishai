class VersionSourceProcessingIdentity < ActiveRecord::Migration[8.1]
  def change
    remove_index :source_snapshots, column: [ :source_id, :digest, :redaction ], unique: true,
      name: "index_source_snapshots_on_source_id_and_digest_and_redaction"
    add_index :source_snapshots, [ :source_id, :digest, :redaction, :processing_version ], unique: true,
      name: "index_source_snapshots_on_processing_identity"
  end
end
