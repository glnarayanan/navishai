class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false

      t.timestamps
    end

    add_index :workspaces, [ :organization_id, :slug ], unique: true
  end
end
