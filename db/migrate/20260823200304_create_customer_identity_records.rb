class CreateCustomerIdentityRecords < ActiveRecord::Migration[8.1]
  def change
    create_customer_records
    create_source_identities
    create_identity_keys_and_candidates
    create_merge_history
  end

  private
    def create_customer_records
      create_table :accounts do |t|
        t.references :workspace, null: false, foreign_key: true
        t.string :name, null: false
        t.timestamps
      end
      add_index :accounts, [ :workspace_id, :name ]
      add_index :accounts, [ :workspace_id, :id ], unique: true

      create_table :contacts do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :account_id
        t.string :name
        t.timestamps
      end
      add_index :contacts, [ :workspace_id, :name ]
      add_index :contacts, [ :workspace_id, :id ], unique: true
      add_index :contacts, [ :workspace_id, :account_id ]
      add_foreign_key :contacts, :accounts,
        column: [ :workspace_id, :account_id ],
        primary_key: [ :workspace_id, :id ]
    end

    def create_source_identities
      create_table :source_identities do |t|
        t.references :workspace, null: false, foreign_key: true
        t.string :entity_kind, null: false
        t.string :source_namespace, null: false
        t.string :source_record_type, null: false
        t.string :source_record_id, null: false
        t.string :status, null: false, default: "pending"
        t.bigint :account_id
        t.bigint :contact_id
        t.string :resolution_method
        t.references :resolved_by, foreign_key: { to_table: :users }
        t.datetime :resolved_at
        t.datetime :retired_at
        t.timestamps
      end
      add_index :source_identities, [ :workspace_id, :id ], unique: true
      add_index :source_identities,
        [ :workspace_id, :source_namespace, :source_record_type, :source_record_id ],
        unique: true,
        name: "index_source_identities_on_source_record"
      add_foreign_key :source_identities, :accounts,
        column: [ :workspace_id, :account_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :source_identities, :contacts,
        column: [ :workspace_id, :contact_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :source_identities,
        "entity_kind IN ('account', 'contact')",
        name: "source_identities_entity_kind"
      add_check_constraint :source_identities,
        "status IN ('pending', 'ambiguous', 'matched')",
        name: "source_identities_status"
      add_check_constraint :source_identities,
        "resolution_method IS NULL OR resolution_method IN ('created', 'deterministic', 'reviewed')",
        name: "source_identities_resolution_method"
      add_check_constraint :source_identities,
        "(status IN ('pending', 'ambiguous') AND account_id IS NULL AND contact_id IS NULL AND resolution_method IS NULL AND resolved_by_id IS NULL AND resolved_at IS NULL) OR " \
        "(status = 'matched' AND ((entity_kind = 'account' AND account_id IS NOT NULL AND contact_id IS NULL) OR (entity_kind = 'contact' AND contact_id IS NOT NULL AND account_id IS NULL)) AND resolution_method IS NOT NULL AND resolved_at IS NOT NULL)",
        name: "source_identities_resolution_state"
    end

    def create_identity_keys_and_candidates
      create_table :source_identity_keys do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :source_identity_id, null: false
        t.string :kind, null: false
        t.string :normalized_value, null: false
        t.datetime :retired_at
        t.timestamps
      end
      add_index :source_identity_keys,
        [ :source_identity_id, :kind, :normalized_value ],
        unique: true,
        where: "retired_at IS NULL",
        name: "index_current_source_identity_keys"
      add_index :source_identity_keys,
        [ :workspace_id, :kind, :normalized_value ],
        where: "retired_at IS NULL",
        name: "index_source_identity_keys_for_matching"
      add_foreign_key :source_identity_keys, :source_identities,
        column: [ :workspace_id, :source_identity_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :source_identity_keys,
        "kind IN ('email', 'domain')",
        name: "source_identity_keys_kind"

      create_table :identity_match_candidates do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :source_identity_id, null: false
        t.bigint :account_id
        t.bigint :contact_id
        t.string :key_kind, null: false
        t.timestamps
      end
      add_index :identity_match_candidates,
        [ :source_identity_id, :account_id, :key_kind ],
        unique: true,
        where: "account_id IS NOT NULL",
        name: "index_identity_candidates_on_account"
      add_index :identity_match_candidates,
        [ :source_identity_id, :contact_id, :key_kind ],
        unique: true,
        where: "contact_id IS NOT NULL",
        name: "index_identity_candidates_on_contact"
      add_foreign_key :identity_match_candidates, :source_identities,
        column: [ :workspace_id, :source_identity_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :identity_match_candidates, :accounts,
        column: [ :workspace_id, :account_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :identity_match_candidates, :contacts,
        column: [ :workspace_id, :contact_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :identity_match_candidates,
        "(account_id IS NOT NULL)::integer + (contact_id IS NOT NULL)::integer = 1",
        name: "identity_match_candidates_one_record"
      add_check_constraint :identity_match_candidates,
        "key_kind IN ('email', 'domain')",
        name: "identity_match_candidates_key_kind"
    end

    def create_merge_history
      create_merge_table(:account_merges, :account)
      create_merge_table(:contact_merges, :contact)
    end

    def create_merge_table(table, record)
      create_table table do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :source_id, null: false
        t.bigint :target_id, null: false
        t.references :merged_by, null: false, foreign_key: { to_table: :users }
        t.datetime :merged_at, null: false
        t.references :unmerged_by, foreign_key: { to_table: :users }
        t.datetime :unmerged_at
        t.timestamps
      end
      add_index table, [ :workspace_id, :source_id ], unique: true, where: "unmerged_at IS NULL", name: "index_active_#{table}_on_source"
      add_foreign_key table, record.to_s.pluralize,
        column: [ :workspace_id, :source_id ],
        primary_key: [ :workspace_id, :id ],
        name: "fk_#{table}_source"
      add_foreign_key table, record.to_s.pluralize,
        column: [ :workspace_id, :target_id ],
        primary_key: [ :workspace_id, :id ],
        name: "fk_#{table}_target"
      add_check_constraint table, "source_id <> target_id", name: "#{table}_different_records"
      add_check_constraint table,
        "(unmerged_by_id IS NULL AND unmerged_at IS NULL) OR (unmerged_by_id IS NOT NULL AND unmerged_at IS NOT NULL)",
        name: "#{table}_unmerge_state"
    end
end
