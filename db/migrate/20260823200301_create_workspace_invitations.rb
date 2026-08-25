class CreateWorkspaceInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_invitations do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :email_address, null: false
      t.string :role, null: false
      t.string :status, null: false
      t.string :token_nonce, null: false
      t.references :invited_by, null: false, foreign_key: { to_table: :users }
      t.references :accepted_by, foreign_key: { to_table: :users }
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.timestamps
    end

    add_check_constraint :workspace_invitations,
      "role IN ('owner', 'admin', 'manager', 'member', 'viewer')",
      name: "workspace_invitations_role"
    add_check_constraint :workspace_invitations,
      "status IN ('pending', 'accepted', 'revoked', 'expired')",
      name: "workspace_invitations_status"
    add_index :workspace_invitations,
      "workspace_id, lower(email_address)",
      unique: true,
      where: "status = 'pending'",
      name: "index_pending_workspace_invitations_on_email"
  end
end
