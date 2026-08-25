class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false

      t.timestamps
    end

    add_index :organizations, :slug, unique: true
  end
end
