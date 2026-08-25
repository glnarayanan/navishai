class ExecutionEvent < ApplicationRecord
  TYPES = %w[
    run.admitted run.started tool.completed output.produced usage.observed
    run.completed run.failed run.timed_out run.canceled run.policy_denied
  ].freeze

  belongs_to :workspace
  belongs_to :execution_run

  validates :event_key, presence: true, uniqueness: true
  validates :sequence_number, numericality: { only_integer: true, greater_than: 0 }
  validates :event_type, inclusion: { in: TYPES }
  validates :occurred_at, presence: true
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :data_is_bounded

  def readonly?
    persisted?
  end

  private
    def data_is_bounded
      unless data.is_a?(Hash) && JSON.generate(data).bytesize <= 128.kilobytes
        errors.add(:data, "must be a JSON object no larger than 128 KiB")
      end
    end
end
