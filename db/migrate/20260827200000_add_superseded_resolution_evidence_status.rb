class AddSupersededResolutionEvidenceStatus < ActiveRecord::Migration[8.1]
  OLD_STATUSES = "'available','stale','expired','deleted','unavailable','conflicted','not_yet_valid'".freeze
  NEW_STATUSES = "'available','stale','expired','deleted','unavailable','conflicted','not_yet_valid','superseded'".freeze

  def up
    replace_statuses(OLD_STATUSES, NEW_STATUSES)
  end

  def down
    replace_statuses(NEW_STATUSES, OLD_STATUSES)
  end

  private
    def replace_statuses(previous, replacement)
      definition = select_value(<<~SQL)
        SELECT pg_get_functiondef('resolution_grounding_valid(jsonb, jsonb)'::regprocedure)
      SQL
      unless definition.scan(previous).one?
        raise ActiveRecord::MigrationError, "resolution evidence statuses have an unexpected definition"
      end

      execute definition.sub(previous, replacement)
    end
end
