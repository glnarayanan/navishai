class Source < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :current_snapshot, class_name: "SourceSnapshot", optional: true
  has_many :source_snapshots
  validates :name, presence: true, length: { maximum: 180 }, uniqueness: { scope: [ :corpus_id, :kind ] }
  validates :kind, inclusion: { in: %w[conversations document traces] }
  validates :expires_at, presence: true

  EXPORT_MAX_RECORDS = 2_000
  EXPORT_MAX_BYTES = 10.megabytes

  def download_snapshot!(snapshot_id:, membership:, confirmation:)
    corpus.with_lock do
      membership = Membership.find(membership.id)
      corpus.authorize_writer!(membership, manage: true)
      reload
      raise ActiveRecord::RecordNotFound if expires_at <= Time.current
      snapshot = source_snapshots.where(workspace_id: workspace_id, corpus_id: corpus_id).find(snapshot_id)
      raise CorpusIntake::Invalid, "Type the source name to confirm download." unless confirmation == name

      items = snapshot.corpus_items.where(workspace_id: workspace_id, corpus_id: corpus_id)
      raise CorpusIntake::Invalid, "Download exceeds 2000 records; no partial file was created." if items.count > EXPORT_MAX_RECORDS
      envelope = { format: "navishai-retained-source-v1", workspace_id:, corpus_id:,
        source: { id: id, name: name, kind: kind },
        snapshot: { id: snapshot.id, number: snapshot.number, digest: snapshot.digest,
          redaction: snapshot.redaction, mask_digest: snapshot.mask_digest, mask_count: snapshot.mask_count,
          processing_version: snapshot.processing_version, intake_time: snapshot.created_at.iso8601(6) } }
      json = JSON.generate(envelope).delete_suffix("}") + ',"records":['
      items.find_each(batch_size: 50).with_index do |item, index|
        json << "," unless index.zero?
        json << JSON.generate({ id: item.id, external_id: item.external_id, title: item.title, text: item.content, context: item.context })
        check_export_bytes!(json.bytesize + 2)
      end
      json << "]}"
      check_export_bytes!(json.bytesize)
      AuditEvent.record!(action: "source.downloaded", source: :web, workspace: workspace,
        actor: membership.user, subject: snapshot)
      json
    end
  end

  def check_export_bytes!(size)
    raise CorpusIntake::Invalid, "Download exceeds 10 MiB of complete JSON; no partial file was created." if size > EXPORT_MAX_BYTES
  end
  private :check_export_bytes!

  def dependent_versions(snapshot: nil)
    snapshots = source_snapshots.where(corpus_id: corpus_id, workspace_id: workspace_id)
    snapshot_ids = snapshot ? snapshots.find(snapshot.id).id : snapshots.select(:id)
    versions = ScenarioVersion.where(corpus_id: corpus_id, workspace_id: workspace_id)
    return versions.none if corpus.eval_definitions_expired?

    versions.joins(scenario_evidence: :corpus_item)
      .where(corpus_items: { source_snapshot_id: snapshot_ids, corpus_id: corpus_id })
      .distinct
  end
end
