class ScopeMemoryIndexExpiryToMemoryAge < ActiveRecord::Migration[8.1]
  OLD_UPDATE = <<~SQL.strip
    UPDATE memory_index_entries
    SET status = 'failed', external_document_id = NULL, external_status = NULL,
        failure_code = 'retention_expired', indexed_at = NULL, updated_at = CURRENT_TIMESTAMP
    WHERE workspace_id = target_workspace_id AND created_at < cutoff AND external_document_id IS NOT NULL;
  SQL

  NEW_UPDATE = <<~SQL.strip
    UPDATE memory_index_entries AS entries
    SET status = 'failed', external_document_id = NULL, external_status = NULL,
        failure_code = 'retention_expired', attempt_count = GREATEST(attempt_count, 1),
        last_attempted_at = COALESCE(last_attempted_at, CURRENT_TIMESTAMP),
        indexed_at = NULL, updated_at = CURRENT_TIMESTAMP
    WHERE entries.workspace_id = target_workspace_id AND EXISTS (
      SELECT 1 FROM memory_records AS records
      WHERE records.workspace_id = target_workspace_id AND records.id = entries.memory_record_id
        AND records.observed_at < cutoff
    );
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
        raise ActiveRecord::MigrationError, "memory index expiry update has an unexpected definition"
      end

      execute definition.sub(previous, replacement)
    end
end
