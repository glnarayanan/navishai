class CrewTemplate < ApplicationRecord
  CREW_KINDS = %w[support customer_success].freeze

  belongs_to :workspace
  has_many :agent_profiles, -> { order(:id) }, dependent: :restrict_with_exception
  has_many :crew_tasks, dependent: :restrict_with_exception

  enum :crew_kind, CREW_KINDS.index_by(&:itself), validate: true

  validates :name, presence: true, length: { maximum: 100 }
  validates :crew_kind, uniqueness: { scope: :workspace_id }

  def readonly?
    persisted?
  end
end
