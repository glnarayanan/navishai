class CrewArtifact < ApplicationRecord
  KINDS = %w[investigation draft quality_review].freeze
  REVIEW_OUTCOMES = %w[approved changes_requested].freeze

  attribute :artifact_key, default: -> { SecureRandom.uuid }

  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :execution_run
  belongs_to :supersedes_artifact, class_name: "CrewArtifact", optional: true
  belongs_to :target_artifact, class_name: "CrewArtifact", optional: true
  has_many :revisions, class_name: "CrewArtifact", foreign_key: :supersedes_artifact_id,
    dependent: :restrict_with_exception, inverse_of: :supersedes_artifact
  has_many :reviews, class_name: "CrewArtifact", foreign_key: :target_artifact_id,
    dependent: :restrict_with_exception, inverse_of: :target_artifact
  has_many :input_runs, class_name: "ExecutionRun", foreign_key: :input_artifact_id,
    dependent: :restrict_with_exception, inverse_of: :input_artifact

  enum :artifact_kind, KINDS.index_by(&:itself), validate: true

  validates :artifact_key, presence: true, uniqueness: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :payload_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :review_outcome, inclusion: { in: REVIEW_OUTCOMES }, allow_nil: true
  validate :content_fits
  validate :shape_is_consistent

  def readonly?
    persisted?
  end

  private
    def content_fits
      errors.add(:body, "must be between 1 byte and 50 KiB") unless body.to_s.bytesize.in?(1..50.kilobytes)
      errors.add(:uncertainty, "must be between 1 and 4,000 bytes") unless uncertainty.to_s.bytesize.in?(1..4_000)
      [ :citations, :conflicts, :change_requests ].each do |name|
        value = public_send(name)
        errors.add(name, "must be an array with at most 20 entries") unless value.is_a?(Array) && value.size <= 20
      end
    end

    def shape_is_consistent
      review = artifact_kind == "quality_review"
      errors.add(:target_artifact, "does not match artifact kind") if review != target_artifact.present?
      errors.add(:review_outcome, "does not match artifact kind") if review != review_outcome.present?
      records = [ crew_task, execution_run, supersedes_artifact, target_artifact ].compact
      errors.add(:base, "records belong to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
      errors.add(:execution_run, "does not belong to task") if execution_run && crew_task && execution_run.crew_task_id != crew_task_id
      if supersedes_artifact &&
          (supersedes_artifact.crew_task_id != crew_task_id || supersedes_artifact.artifact_kind != artifact_kind ||
          supersedes_artifact.version_number != version_number - 1)
        errors.add(:supersedes_artifact, "does not precede this version")
      end
    end
end
