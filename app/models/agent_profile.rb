class AgentProfile < ApplicationRecord
  belongs_to :workspace
  belongs_to :crew_template
  belongs_to :current_version, class_name: "AgentProfileVersion", optional: true
  has_many :versions, -> { order(version_number: :desc) },
    class_name: "AgentProfileVersion", dependent: :restrict_with_exception
  has_many :assigned_crew_tasks, class_name: "CrewTask", foreign_key: :assigned_agent_profile_id,
    dependent: :restrict_with_exception
  has_many :memory_proposals, foreign_key: :source_agent_profile_id, dependent: :restrict_with_exception,
    inverse_of: :source_agent_profile

  validates :role_key, presence: true, inclusion: { in: AgentPolicy::ROLE_DEFINITIONS }
  validates :role_key, uniqueness: { scope: :crew_template_id }
  validates :name, presence: true, length: { maximum: 100 }
  validate :role_matches_crew

  private
    def role_matches_crew
      return if role_key.blank? || crew_template.nil?

      expected_kind = AgentPolicy.definition(role_key).fetch(:crew_kind)
      errors.add(:role_key, "does not belong to this crew") unless crew_template.crew_kind == expected_kind
    end
end
