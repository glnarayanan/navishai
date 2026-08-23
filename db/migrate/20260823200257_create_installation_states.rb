class CreateInstallationStates < ActiveRecord::Migration[8.1]
  def change
    create_table :installation_states do |t|
      t.boolean :singleton, null: false, default: true
      t.datetime :bootstrapped_at, null: false
      t.timestamps
    end

    add_index :installation_states, :singleton, unique: true
    add_check_constraint :installation_states, "singleton", name: "installation_states_singleton"
  end
end
