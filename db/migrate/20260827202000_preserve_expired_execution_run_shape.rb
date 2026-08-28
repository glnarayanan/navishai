class PreserveExpiredExecutionRunShape < ActiveRecord::Migration[8.1]
  OLD_UPDATE = <<~SQL.strip
    UPDATE execution_runs
    SET input_context = '[Expired by retention policy]', output = CASE WHEN output IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
        last_admission_error = NULL, runtime_selection_detail = NULL, memory_context_detail = NULL, updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND created_at < cutoff AND
      (input_context IS DISTINCT FROM '[Expired by retention policy]' OR
       (output IS NOT NULL AND output <> '[Expired by retention policy]') OR
       last_admission_error IS NOT NULL OR runtime_selection_detail IS NOT NULL OR memory_context_detail IS NOT NULL);
  SQL

  NEW_UPDATE = <<~SQL.strip
    UPDATE execution_runs
    SET input_context = '[Expired by retention policy]',
        output = CASE WHEN output IS NULL THEN NULL ELSE '[Expired by retention policy]' END,
        last_admission_error = NULL,
        runtime_selection_detail = '[Expired by retention policy]',
        memory_context_detail = CASE
          WHEN memory_context_status = 'degraded' THEN '[Expired by retention policy]'
          ELSE NULL
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND created_at < cutoff AND
      (input_context IS DISTINCT FROM '[Expired by retention policy]' OR
       (output IS NOT NULL AND output <> '[Expired by retention policy]') OR
       last_admission_error IS NOT NULL OR
       runtime_selection_detail IS DISTINCT FROM '[Expired by retention policy]' OR
       memory_context_detail IS DISTINCT FROM CASE
         WHEN memory_context_status = 'degraded' THEN '[Expired by retention policy]'
         ELSE NULL
       END);
  SQL

  def up
    replace_expiry_update(OLD_UPDATE, NEW_UPDATE)
  end

  def down
    replace_expiry_update(NEW_UPDATE, OLD_UPDATE)
  end

  private
    def replace_expiry_update(previous, replacement)
      definition = select_value(<<~SQL)
        SELECT pg_get_functiondef(
          'expire_workspace_content(bigint, timestamp without time zone)'::regprocedure
        )
      SQL
      previous = previous.lines.map { |line| "  #{line}" }.join
      replacement = replacement.lines.map { |line| "  #{line}" }.join
      unless definition.include?(previous)
        raise ActiveRecord::MigrationError, "execution run expiry update has an unexpected definition"
      end

      execute definition.sub(previous, replacement)
    end
end
