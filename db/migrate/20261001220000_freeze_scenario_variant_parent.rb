class FreezeScenarioVariantParent < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE TRIGGER scenario_parent_immutable BEFORE UPDATE OF parent_version_id ON scenarios
      FOR EACH ROW WHEN (OLD.parent_version_id IS DISTINCT FROM NEW.parent_version_id)
      EXECUTE FUNCTION prevent_lab_version_update()
    SQL
  end

  def down
    execute "DROP TRIGGER scenario_parent_immutable ON scenarios"
  end
end
