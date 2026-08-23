class CreateAuditEvents < ActiveRecord::Migration[8.1]
  ACTOR_KINDS = %w[user break_glass system anonymous].freeze
  SOURCES = %w[web job task runner integration system].freeze

  def change
    create_table :audit_events do |t|
      t.references :workspace, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :actor_kind, null: false
      t.string :source, null: false
      t.string :action, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.jsonb :metadata, null: false, default: {}
      t.string :request_id
      t.inet :ip_address
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end

    add_check_constraint :audit_events,
      "actor_kind IN (#{ACTOR_KINDS.map { |kind| quote(kind) }.join(', ')})",
      name: "audit_events_actor_kind"
    add_check_constraint :audit_events,
      "source IN (#{SOURCES.map { |source| quote(source) }.join(', ')})",
      name: "audit_events_source"
    add_check_constraint :audit_events,
      "((actor_kind IN ('user', 'break_glass')) = (actor_id IS NOT NULL))",
      name: "audit_events_actor_presence"
    add_check_constraint :audit_events,
      "action ~ '^[a-z0-9]+([._][a-z0-9]+)*$'",
      name: "audit_events_action_format"
    add_index :audit_events, [ :workspace_id, :occurred_at ]
    add_index :audit_events, [ :actor_id, :occurred_at ]
    add_index :audit_events, [ :action, :occurred_at ]
    add_index :audit_events, [ :subject_type, :subject_id ]

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION prevent_audit_event_mutation()
          RETURNS trigger
          LANGUAGE plpgsql
          AS $$
          BEGIN
            RAISE EXCEPTION 'audit events are append-only';
          END;
          $$;

          CREATE TRIGGER audit_events_append_only
          BEFORE UPDATE OR DELETE ON audit_events
          FOR EACH ROW
          EXECUTE FUNCTION prevent_audit_event_mutation();

          CREATE TRIGGER audit_events_no_truncate
          BEFORE TRUNCATE ON audit_events
          FOR EACH STATEMENT
          EXECUTE FUNCTION prevent_audit_event_mutation();
        SQL
      end

      direction.down do
        execute "DROP TRIGGER IF EXISTS audit_events_no_truncate ON audit_events"
        execute "DROP TRIGGER IF EXISTS audit_events_append_only ON audit_events"
        execute "DROP FUNCTION IF EXISTS prevent_audit_event_mutation()"
      end
    end
  end
end
