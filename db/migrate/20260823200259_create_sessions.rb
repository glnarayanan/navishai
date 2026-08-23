class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :sessions, :expires_at
  end
end
