class IndexCorpusItemsByExternalId < ActiveRecord::Migration[8.1]
  # Discovery pages corpus items by (external_id, id); without this index each
  # 100-row page sorts the whole corpus.
  def change
    add_index :corpus_items, [ :workspace_id, :corpus_id, :external_id, :id ]
  end
end
