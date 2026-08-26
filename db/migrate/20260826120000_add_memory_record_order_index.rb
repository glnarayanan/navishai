class AddMemoryRecordOrderIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :memory_records, [ :workspace_id, :observed_at, :id ],
      order: { observed_at: :desc, id: :desc }, algorithm: :concurrently
  end
end
