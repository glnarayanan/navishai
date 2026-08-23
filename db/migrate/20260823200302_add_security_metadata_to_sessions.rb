class AddSecurityMetadataToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :authentication_method, :string, null: false, default: "local"
    change_column_default :sessions, :authentication_method, from: "local", to: nil
    add_column :sessions, :revoked_at, :datetime
    add_check_constraint :sessions,
      "authentication_method IN ('local', 'break_glass')",
      name: "sessions_authentication_method"
  end
end
