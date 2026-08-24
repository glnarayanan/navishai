class CreateMemoryGovernanceRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :memory_correction_proposals do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :memory_record, null: false
      t.bigint :proposed_by_membership_id, null: false
      t.bigint :proposed_by_user_id, null: false
      t.bigint :reviewed_by_membership_id
      t.bigint :reviewed_by_user_id
      t.bigint :published_memory_record_id
      t.uuid :proposal_key, null: false, default: -> { "gen_random_uuid()" }
      t.text :content, null: false
      t.string :content_digest, null: false
      t.decimal :confidence, precision: 4, scale: 3, null: false
      t.string :retention_policy, null: false
      t.datetime :retention_until
      t.string :status, null: false, default: "proposed"
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :memory_correction_proposals, :proposal_key, unique: true
    add_index :memory_correction_proposals, [ :workspace_id, :id ], unique: true
    add_index :memory_correction_proposals, [ :workspace_id, :status ]
    add_foreign_key :memory_correction_proposals, :memory_records,
      column: [ :workspace_id, :memory_record_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_correction_proposals, :memberships,
      column: [ :workspace_id, :proposed_by_membership_id, :proposed_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_memory_corrections_proposer"
    add_foreign_key :memory_correction_proposals, :memberships,
      column: [ :workspace_id, :reviewed_by_membership_id, :reviewed_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_memory_corrections_reviewer"
    add_foreign_key :memory_correction_proposals, :memory_records,
      column: [ :workspace_id, :published_memory_record_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_memory_corrections_publication"
    add_check_constraint :memory_correction_proposals,
      "octet_length(content) BETWEEN 1 AND 32768 AND content_digest ~ '^[0-9a-f]{64}$' AND " \
      "confidence BETWEEN 0.000 AND 1.000", name: "memory_corrections_content"
    add_check_constraint :memory_correction_proposals,
      "retention_policy IN ('indefinite', 'time_bound') AND " \
      "((retention_policy = 'time_bound' AND retention_until IS NOT NULL) OR " \
      "(retention_policy = 'indefinite' AND retention_until IS NULL))", name: "memory_corrections_retention"
    add_check_constraint :memory_correction_proposals,
      "(status = 'proposed' AND reviewed_by_membership_id IS NULL AND reviewed_by_user_id IS NULL AND " \
      "published_memory_record_id IS NULL AND reviewed_at IS NULL) OR " \
      "(status = 'accepted' AND reviewed_by_membership_id IS NOT NULL AND reviewed_by_user_id IS NOT NULL AND " \
      "published_memory_record_id IS NOT NULL AND reviewed_at IS NOT NULL) OR " \
      "(status = 'rejected' AND reviewed_by_membership_id IS NOT NULL AND reviewed_by_user_id IS NOT NULL AND " \
      "published_memory_record_id IS NULL AND reviewed_at IS NOT NULL)", name: "memory_corrections_review"

    create_table :memory_tombstones do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.references :memory_record, null: false
      t.bigint :deleted_by_membership_id, null: false
      t.bigint :deleted_by_user_id, null: false
      t.string :reason, null: false
      t.string :index_status, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.string :failure_code
      t.datetime :last_attempted_at
      t.datetime :removed_at
      t.timestamps
    end
    add_index :memory_tombstones, [ :workspace_id, :id ], unique: true
    add_index :memory_tombstones, [ :workspace_id, :memory_record_id ], unique: true
    add_index :memory_tombstones, [ :workspace_id, :index_status ]
    add_foreign_key :memory_tombstones, :memory_records,
      column: [ :workspace_id, :memory_record_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :memory_tombstones, :memberships,
      column: [ :workspace_id, :deleted_by_membership_id, :deleted_by_user_id ],
      primary_key: [ :workspace_id, :id, :user_id ], name: "fk_memory_tombstones_actor"
    add_check_constraint :memory_tombstones,
      "octet_length(reason) BETWEEN 1 AND 500", name: "memory_tombstones_reason"
    add_check_constraint :memory_tombstones,
      "(index_status = 'pending' AND attempt_count = 0 AND failure_code IS NULL AND last_attempted_at IS NULL AND removed_at IS NULL) OR " \
      "(index_status = 'removing' AND attempt_count > 0 AND failure_code IS NULL AND last_attempted_at IS NOT NULL AND removed_at IS NULL) OR " \
      "(index_status = 'removed' AND attempt_count > 0 AND failure_code IS NULL AND last_attempted_at IS NOT NULL AND removed_at IS NOT NULL) OR " \
      "(index_status IN ('failed', 'unknown') AND attempt_count > 0 AND failure_code IS NOT NULL AND " \
      "last_attempted_at IS NOT NULL AND removed_at IS NULL)", name: "memory_tombstones_state"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_memory_correction_proposal()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'TRUNCATE' THEN
              RAISE EXCEPTION 'memory correction proposals cannot be truncated';
            END IF;
            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            IF TG_OP = 'DELETE' OR ROW(OLD.id, OLD.workspace_id, OLD.memory_record_id,
              OLD.proposed_by_membership_id, OLD.proposed_by_user_id, OLD.proposal_key, OLD.content,
              OLD.content_digest, OLD.confidence, OLD.retention_policy, OLD.retention_until, OLD.created_at)
              IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.memory_record_id,
              NEW.proposed_by_membership_id, NEW.proposed_by_user_id, NEW.proposal_key, NEW.content,
              NEW.content_digest, NEW.confidence, NEW.retention_policy, NEW.retention_until, NEW.created_at) THEN
              RAISE EXCEPTION 'memory correction proposal identity is immutable';
            END IF;
            IF OLD.status <> 'proposed' OR NEW.status NOT IN ('accepted', 'rejected') THEN
              RAISE EXCEPTION 'memory correction review is terminal';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER memory_correction_proposals_protect
          BEFORE UPDATE OR DELETE ON memory_correction_proposals
          FOR EACH ROW EXECUTE FUNCTION protect_memory_correction_proposal();
          CREATE TRIGGER memory_correction_proposals_no_truncate
          BEFORE TRUNCATE ON memory_correction_proposals
          FOR EACH STATEMENT EXECUTE FUNCTION protect_memory_correction_proposal();

          CREATE FUNCTION protect_memory_tombstone()
          RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF TG_OP = 'TRUNCATE' THEN
              RAISE EXCEPTION 'memory tombstones cannot be truncated';
            END IF;
            IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM workspaces WHERE id = OLD.workspace_id) THEN
              RETURN OLD;
            END IF;
            IF TG_OP = 'DELETE' OR ROW(OLD.id, OLD.workspace_id, OLD.memory_record_id,
              OLD.deleted_by_membership_id, OLD.deleted_by_user_id, OLD.reason, OLD.created_at)
              IS DISTINCT FROM ROW(NEW.id, NEW.workspace_id, NEW.memory_record_id,
              NEW.deleted_by_membership_id, NEW.deleted_by_user_id, NEW.reason, NEW.created_at) THEN
              RAISE EXCEPTION 'memory tombstone identity is immutable';
            END IF;
            IF NOT ((OLD.index_status IN ('pending', 'failed', 'unknown') AND NEW.index_status = 'removing') OR
                    (OLD.index_status = 'removing' AND NEW.index_status IN ('removed', 'failed', 'unknown'))) THEN
              RAISE EXCEPTION 'memory tombstone transition is invalid';
            END IF;
            RETURN NEW;
          END;
          $$;
          CREATE TRIGGER memory_tombstones_protect
          BEFORE UPDATE OR DELETE ON memory_tombstones
          FOR EACH ROW EXECUTE FUNCTION protect_memory_tombstone();
          CREATE TRIGGER memory_tombstones_no_truncate
          BEFORE TRUNCATE ON memory_tombstones
          FOR EACH STATEMENT EXECUTE FUNCTION protect_memory_tombstone();
        SQL
      end
      direction.down do
        execute <<~SQL
          DROP TRIGGER memory_tombstones_no_truncate ON memory_tombstones;
          DROP TRIGGER memory_tombstones_protect ON memory_tombstones;
          DROP FUNCTION protect_memory_tombstone();
          DROP TRIGGER memory_correction_proposals_no_truncate ON memory_correction_proposals;
          DROP TRIGGER memory_correction_proposals_protect ON memory_correction_proposals;
          DROP FUNCTION protect_memory_correction_proposal();
        SQL
      end
    end
  end
end
