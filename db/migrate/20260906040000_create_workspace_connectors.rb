class CreateWorkspaceConnectors < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_connectors do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      t.boolean :enabled, null: false, default: false
      t.text :service_token
      t.timestamps
    end
    add_index :workspace_connectors, [ :workspace_id, :provider ], unique: true
    add_index :workspace_connectors, [ :workspace_id, :id ], unique: true
    add_check_constraint :workspace_connectors, "provider IN ('intercom', 'notion')", name: "workspace_connectors_provider"

    create_table :integration_user_connections do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :workspace_connector_id, null: false
      t.bigint :membership_id, null: false
      t.string :remote_user_id, null: false
      t.string :remote_workspace_id, null: false
      t.text :access_token, null: false
      t.text :refresh_token
      t.datetime :expires_at
      t.timestamps
    end
    add_foreign_key :integration_user_connections, :workspace_connectors,
      column: [ :workspace_id, :workspace_connector_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_foreign_key :integration_user_connections, :memberships,
      column: [ :workspace_id, :membership_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_index :integration_user_connections, [ :workspace_connector_id, :membership_id ], unique: true

    create_table :integration_oauth_attempts do |t|
      t.references :workspace, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :workspace_connector_id, null: false
      t.bigint :membership_id, null: false
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.string :state_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_foreign_key :integration_oauth_attempts, :workspace_connectors,
      column: [ :workspace_id, :workspace_connector_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_foreign_key :integration_oauth_attempts, :memberships,
      column: [ :workspace_id, :membership_id ], primary_key: [ :workspace_id, :id ], on_delete: :cascade
    add_index :integration_oauth_attempts, :state_digest, unique: true
  end
end
