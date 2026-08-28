require "digest"

class AddBusinessEvidenceToAccountHealth < ActiveRecord::Migration[8.1]
  def up
    add_column :account_health_inputs, :source_namespace, :string
    add_column :account_health_inputs, :source_digest, :string
    add_column :account_health_inputs, :valid_from, :datetime
    add_column :account_health_inputs, :valid_until, :datetime
    add_column :account_health_inputs, :corrects_account_health_input_id, :bigint

    execute "ALTER TABLE account_health_inputs DISABLE TRIGGER account_health_inputs_append_only"
    select_all(<<~SQL.squish).each do |row|
      SELECT id, source_kind, source_key, input_key, value_kind, numeric_value, date_value
      FROM account_health_inputs
    SQL
      value = row.fetch("value_kind") == "date" ? row.fetch("date_value").to_s : BigDecimal(row.fetch("numeric_value")).to_s("F")
      digest = Digest::SHA256.hexdigest([ row.fetch("input_key"), row.fetch("value_kind"), value ].join("\n"))
      execute <<~SQL.squish
        UPDATE account_health_inputs
        SET source_namespace = #{quote("#{row.fetch('source_kind')}_import")},
            source_digest = #{quote(digest)}
        WHERE id = #{quote(row.fetch('id'))}
      SQL
    end
    execute "ALTER TABLE account_health_inputs ENABLE TRIGGER account_health_inputs_append_only"

    change_column_null :account_health_inputs, :source_namespace, false
    change_column_null :account_health_inputs, :source_digest, false
    add_check_constraint :account_health_inputs,
      "source_namespace ~ '^[a-z][a-z0-9_.:-]{0,99}$' AND source_digest ~ '^[0-9a-f]{64}$'",
      name: "account_health_inputs_business_source"
    add_check_constraint :account_health_inputs,
      "valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from",
      name: "account_health_inputs_validity"
    remove_index :account_health_inputs, name: "index_account_health_inputs_on_source"
    add_index :account_health_inputs, [ :workspace_id, :source_namespace, :source_key, :input_key ],
      unique: true, name: "index_account_health_inputs_on_business_source"
    add_index :account_health_inputs, [ :workspace_id, :account_id, :input_key, :id ],
      unique: true, name: "index_account_health_inputs_correction_target"
    add_foreign_key :account_health_inputs, :account_health_inputs,
      column: [ :workspace_id, :account_id, :input_key, :corrects_account_health_input_id ],
      primary_key: [ :workspace_id, :account_id, :input_key, :id ],
      name: "fk_account_health_inputs_correction"

    add_column :account_health_signals, :evidence_refs, :jsonb, null: false, default: []
    add_column :account_health_signals, :evidence_omitted_count, :integer, null: false, default: 0
    add_check_constraint :account_health_signals,
      "jsonb_typeof(evidence_refs) = 'array' AND jsonb_array_length(evidence_refs) <= 100 AND evidence_omitted_count >= 0",
      name: "account_health_signals_evidence"
    remove_check_constraint :account_health_signals, name: "account_health_signals_source_kind"
    add_check_constraint :account_health_signals,
      "source_kind IN ('account_input', 'support_cases', 'sla', 'conversation', 'case_notes', " \
      "'case_tags', 'case_status', 'resolution_contract')",
      name: "account_health_signals_source_kind"
  end

  def down
    remove_check_constraint :account_health_signals, name: "account_health_signals_source_kind"
    add_check_constraint :account_health_signals,
      "source_kind IN ('account_input', 'support_cases', 'sla', 'conversation', 'case_notes')",
      name: "account_health_signals_source_kind"
    remove_check_constraint :account_health_signals, name: "account_health_signals_evidence"
    remove_column :account_health_signals, :evidence_omitted_count
    remove_column :account_health_signals, :evidence_refs

    remove_foreign_key :account_health_inputs, name: "fk_account_health_inputs_correction"
    remove_index :account_health_inputs, name: "index_account_health_inputs_correction_target"
    remove_index :account_health_inputs, name: "index_account_health_inputs_on_business_source"
    add_index :account_health_inputs, [ :workspace_id, :source_kind, :source_key, :input_key ],
      unique: true, name: "index_account_health_inputs_on_source"
    remove_check_constraint :account_health_inputs, name: "account_health_inputs_validity"
    remove_check_constraint :account_health_inputs, name: "account_health_inputs_business_source"
    remove_column :account_health_inputs, :corrects_account_health_input_id
    remove_column :account_health_inputs, :valid_until
    remove_column :account_health_inputs, :valid_from
    remove_column :account_health_inputs, :source_digest
    remove_column :account_health_inputs, :source_namespace
  end
end
