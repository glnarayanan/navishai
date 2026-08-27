class CreateResolutionContracts < ActiveRecord::Migration[8.1]
  CLAIM_CATEGORIES = %w[
    customer_account_fact product_technical_fact policy_entitlement promised_action_date
  ].freeze
  SOURCE_KINDS = %w[knowledge conversation case account health_signal public_web memory].freeze
  REVIEW_CHECKS = %w[
    claims_grounded conflicts_resolved uncertainty_stated human_authority_preserved
  ].sort.freeze
  DEFAULT_FRESHNESS = {
    "knowledge" => 30,
    "conversation" => 365,
    "case" => 30,
    "account" => 30,
    "health_signal" => 14,
    "public_web" => 7,
    "memory" => 30
  }.freeze
  DEFAULT_CATEGORIES = {
    "support_resolution" => %w[customer_account_fact product_technical_fact],
    "customer_success_intervention" => %w[customer_account_fact promised_action_date]
  }.freeze

  def change
    create_table :resolution_contract_families do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :family_key, null: false
      t.bigint :current_version_id
      t.timestamps
    end
    add_index :resolution_contract_families, [ :workspace_id, :family_key ], unique: true,
      name: "index_resolution_contract_families_unique"
    add_index :resolution_contract_families, [ :workspace_id, :id ], unique: true

    create_table :resolution_contract_versions do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :resolution_contract_family_id, null: false
      t.integer :version_number, null: false
      t.jsonb :required_claim_categories, null: false, default: []
      t.jsonb :evidence_freshness_days, null: false, default: {}
      t.jsonb :mandatory_review_checks, null: false, default: []
      t.integer :execution_budget_units, null: false
      t.boolean :missing_items_block, null: false, default: true
      t.bigint :created_by_membership_id
      t.bigint :created_by_user_id
      t.timestamps
    end
    add_index :resolution_contract_versions,
      [ :resolution_contract_family_id, :version_number ], unique: true,
      name: "index_resolution_contract_versions_on_family_version"
    add_index :resolution_contract_versions, [ :workspace_id, :id ], unique: true
    add_index :resolution_contract_versions,
      [ :workspace_id, :resolution_contract_family_id, :id ], unique: true,
      name: "index_resolution_contract_versions_tenant_chain"
    add_foreign_key :resolution_contract_versions, :resolution_contract_families,
      column: [ :workspace_id, :resolution_contract_family_id ],
      primary_key: [ :workspace_id, :id ], name: "fk_resolution_contract_versions_family"
    add_foreign_key :resolution_contract_versions, :memberships,
      column: [ :workspace_id, :created_by_membership_id, :created_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_resolution_contract_versions_actor"
    add_foreign_key :resolution_contract_versions, :users, column: :created_by_user_id
    add_foreign_key :resolution_contract_families, :resolution_contract_versions,
      column: [ :workspace_id, :id, :current_version_id ],
      primary_key: [ :workspace_id, :resolution_contract_family_id, :id ],
      name: "fk_resolution_contract_families_current_version"

    add_check_constraint :resolution_contract_families,
      "family_key IN ('support_resolution', 'customer_success_intervention')",
      name: "resolution_contract_families_key"
    add_check_constraint :resolution_contract_versions, "version_number > 0",
      name: "resolution_contract_versions_number"
    add_check_constraint :resolution_contract_versions,
      "jsonb_typeof(required_claim_categories) = 'array' AND " \
      "jsonb_array_length(required_claim_categories) BETWEEN 1 AND 4 AND " \
      "required_claim_categories <@ '[\"customer_account_fact\",\"product_technical_fact\",\"policy_entitlement\",\"promised_action_date\"]'::jsonb AND " \
      "jsonb_typeof(evidence_freshness_days) = 'object' AND " \
      "evidence_freshness_days ?& ARRAY['knowledge','conversation','case','account','health_signal','public_web','memory'] AND " \
      "evidence_freshness_days - ARRAY['knowledge','conversation','case','account','health_signal','public_web','memory'] = '{}'::jsonb AND " \
      "jsonb_typeof(evidence_freshness_days->'knowledge') = 'number' AND (evidence_freshness_days->>'knowledge')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(evidence_freshness_days->'conversation') = 'number' AND (evidence_freshness_days->>'conversation')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(evidence_freshness_days->'case') = 'number' AND (evidence_freshness_days->>'case')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(evidence_freshness_days->'account') = 'number' AND (evidence_freshness_days->>'account')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(evidence_freshness_days->'health_signal') = 'number' AND (evidence_freshness_days->>'health_signal')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(evidence_freshness_days->'public_web') = 'number' AND (evidence_freshness_days->>'public_web')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(evidence_freshness_days->'memory') = 'number' AND (evidence_freshness_days->>'memory')::integer BETWEEN 1 AND 3650 AND " \
      "jsonb_typeof(mandatory_review_checks) = 'array' AND " \
      "jsonb_array_length(mandatory_review_checks) BETWEEN 1 AND 4 AND " \
      "mandatory_review_checks <@ '[\"claims_grounded\",\"conflicts_resolved\",\"uncertainty_stated\",\"human_authority_preserved\"]'::jsonb",
      name: "resolution_contract_versions_collections"
    add_check_constraint :resolution_contract_versions,
      "execution_budget_units BETWEEN 1 AND 20000000",
      name: "resolution_contract_versions_budget"
    add_check_constraint :resolution_contract_versions,
      "(created_by_membership_id IS NULL AND created_by_user_id IS NULL) OR " \
      "(created_by_membership_id IS NOT NULL AND created_by_user_id IS NOT NULL)",
      name: "resolution_contract_versions_actor"

    reversible do |direction|
      direction.up do
        install_defaults
        protect_contracts
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS validate_resolution_contract_family_published() CASCADE"
        execute "DROP FUNCTION IF EXISTS protect_resolution_contract_family() CASCADE"
        execute "DROP FUNCTION IF EXISTS protect_resolution_contract_version() CASCADE"
      end
    end
  end

  private
    def install_defaults
      freshness = connection.quote(DEFAULT_FRESHNESS.to_json)
      checks = connection.quote(REVIEW_CHECKS.to_json)
      support_categories = connection.quote(DEFAULT_CATEGORIES.fetch("support_resolution").to_json)
      success_categories = connection.quote(DEFAULT_CATEGORIES.fetch("customer_success_intervention").to_json)
      execute <<~SQL
        INSERT INTO resolution_contract_families (workspace_id, family_key, created_at, updated_at)
        SELECT id, family_key, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM workspaces
        CROSS JOIN (VALUES ('support_resolution'), ('customer_success_intervention')) AS families(family_key);

        INSERT INTO resolution_contract_versions (
          workspace_id, resolution_contract_family_id, version_number, required_claim_categories,
          evidence_freshness_days, mandatory_review_checks, execution_budget_units,
          missing_items_block, created_at, updated_at
        )
        SELECT family.workspace_id, family.id, 1,
          CASE family.family_key
            WHEN 'support_resolution' THEN #{support_categories}::jsonb
            ELSE #{success_categories}::jsonb
          END,
          #{freshness}::jsonb, #{checks}::jsonb, 100000, TRUE,
          CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM resolution_contract_families family;

        UPDATE resolution_contract_families family
        SET current_version_id = version.id, updated_at = CURRENT_TIMESTAMP
        FROM resolution_contract_versions version
        WHERE version.resolution_contract_family_id = family.id AND version.version_number = 1;
      SQL
    end

    def protect_contracts
      execute <<~SQL
        CREATE FUNCTION validate_resolution_contract_family_published()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM resolution_contract_families
            WHERE id = NEW.id AND current_version_id IS NOT NULL
          ) THEN
            RAISE EXCEPTION 'resolution contract family must have one published version';
          END IF;
          RETURN NULL;
        END;
        $$;
        CREATE CONSTRAINT TRIGGER resolution_contract_families_require_published
          AFTER INSERT OR UPDATE ON resolution_contract_families
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION validate_resolution_contract_family_published();

        CREATE FUNCTION protect_resolution_contract_family()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          IF TG_OP = 'UPDATE' AND
             ROW(OLD.id, OLD.workspace_id, OLD.family_key, OLD.created_at)
               IS NOT DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.family_key, NEW.created_at) AND
             OLD.current_version_id IS DISTINCT FROM NEW.current_version_id THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'resolution contract families are durable';
        END;
        $$;
        CREATE TRIGGER resolution_contract_families_protect
          BEFORE UPDATE OR DELETE ON resolution_contract_families
          FOR EACH ROW EXECUTE FUNCTION protect_resolution_contract_family();
        CREATE TRIGGER resolution_contract_families_no_truncate
          BEFORE TRUNCATE ON resolution_contract_families
          FOR EACH STATEMENT EXECUTE FUNCTION protect_resolution_contract_family();

        CREATE FUNCTION protect_resolution_contract_version()
        RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'resolution contract versions are append only';
        END;
        $$;
        CREATE TRIGGER resolution_contract_versions_append_only
          BEFORE UPDATE OR DELETE ON resolution_contract_versions
          FOR EACH ROW EXECUTE FUNCTION protect_resolution_contract_version();
        CREATE TRIGGER resolution_contract_versions_no_truncate
          BEFORE TRUNCATE ON resolution_contract_versions
          FOR EACH STATEMENT EXECUTE FUNCTION protect_resolution_contract_version();
      SQL
    end
end
