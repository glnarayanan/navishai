class AddExactTextMasking < ActiveRecord::Migration[8.1]
  def change
    empty_digest = Digest::SHA256.hexdigest("[]")
    add_column :source_snapshots, :mask_digest, :string, null: false, default: empty_digest
    add_column :source_snapshots, :mask_count, :integer, null: false, default: 0
    remove_check_constraint :source_snapshots,
      "number > 0 AND digest ~ '^[0-9a-f]{64}$' AND redaction IN ('email', 'none')", name: "chk_rails_75987cdd84"
    add_check_constraint :source_snapshots,
      "number > 0 AND digest ~ '^[0-9a-f]{64}$' AND redaction IN ('email', 'none', 'exact')", name: "chk_rails_75987cdd84"
    add_check_constraint :source_snapshots, "mask_digest ~ '^[0-9a-f]{64}$' AND
      ((redaction = 'exact' AND mask_count BETWEEN 1 AND 50 AND mask_digest <> '#{empty_digest}') OR
       (redaction IN ('email', 'none') AND mask_count = 0 AND mask_digest = '#{empty_digest}'))", name: "source_snapshot_mask_policy"
    remove_index :source_snapshots, column: [ :source_id, :digest, :redaction, :processing_version ], unique: true,
      name: "index_source_snapshots_on_processing_identity"
    add_index :source_snapshots, [ :source_id, :digest, :redaction, :processing_version, :mask_digest ], unique: true,
      name: "index_source_snapshots_on_processing_identity"
  end
end
