module CorporaHelper
  def source_evidence_path(item)
    page_number = item.source_snapshot.corpus_items.where("id < ?", item.id).count / 50 + 1
    workspace_corpus_source_path(item.workspace, item.corpus, item.source_snapshot.source_id,
      snapshot: item.source_snapshot.number, page: page_number, anchor: "record-#{item.id}")
  end
end
