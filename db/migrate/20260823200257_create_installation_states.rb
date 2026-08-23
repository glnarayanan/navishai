class CreateInstallationStates < ActiveRecord::Migration[8.1]
  def change
    create_table :installation_states do |t|
      t.boolean :singleton, null: false, default: true
      t.datetime :bootstrapped_at, null: false
      t.timestamps
    end

    add_index :installation_states, :singleton, unique: true
    add_check_constraint :installation_states, "singleton", name: "installation_states_singleton"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          INSERT INTO installation_states (singleton, bootstrapped_at, created_at, updated_at)
          SELECT TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
          WHERE EXISTS (SELECT 1 FROM users) OR EXISTS (SELECT 1 FROM organizations)
        SQL
      end
    end
  end
end
