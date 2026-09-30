class AddProductionTraceSources < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :sources, "kind IN ('conversations', 'document')"
    add_check_constraint :sources, "kind IN ('conversations', 'document', 'traces')"
  end

  def down
    remove_check_constraint :sources, "kind IN ('conversations', 'document', 'traces')"
    add_check_constraint :sources, "kind IN ('conversations', 'document')"
  end
end
