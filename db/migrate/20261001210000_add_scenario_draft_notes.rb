class AddScenarioDraftNotes < ActiveRecord::Migration[8.1]
  def change
    add_column :scenario_versions, :draft_notes, :jsonb, null: false, default: {}
    add_check_constraint :scenario_versions,
      "jsonb_typeof(draft_notes) = 'object' AND octet_length(draft_notes::text) <= 10240",
      name: "scenario_draft_notes_bounded"
  end
end
