class BindIntercomServiceCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_connectors, :service_remote_workspace_id, :string
  end
end
