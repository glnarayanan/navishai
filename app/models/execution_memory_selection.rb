class ExecutionMemorySelection < ApplicationRecord
  belongs_to :workspace
  belongs_to :execution_run
  belongs_to :memory_record

  validates :rank, numericality: { only_integer: true, in: 1..8 }
  validates :relevance_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validate :records_share_workspace

  def readonly?
    persisted?
  end

  def citation_uri
    "memory://#{memory_record.memory_key}"
  end

  private
    def records_share_workspace
      records = [ execution_run, memory_record ].compact
      errors.add(:base, "records belong to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
    end
end
