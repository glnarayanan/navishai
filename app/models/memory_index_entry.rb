class MemoryIndexEntry < ApplicationRecord
  STATUSES = %w[pending indexing queued indexed failed unknown].freeze

  belongs_to :workspace
  belongs_to :memory_record

  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :external_document_id, length: { maximum: 200 }, allow_nil: true
  validates :failure_code, format: { with: /\A[a-z][a-z0-9_]{0,99}\z/ }, allow_nil: true
  validate :record_belongs_to_workspace

  private
    def record_belongs_to_workspace
      errors.add(:memory_record, "belongs to another workspace") if memory_record && memory_record.workspace_id != workspace_id
    end
end
