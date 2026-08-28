class ResolutionContractFamily < ApplicationRecord
  FAMILIES = {
    "support_resolution" => "Support resolution",
    "customer_success_intervention" => "Customer Success intervention"
  }.freeze

  belongs_to :workspace
  belongs_to :current_version, class_name: "ResolutionContractVersion", optional: true
  has_many :versions, -> { order(version_number: :desc) },
    class_name: "ResolutionContractVersion", dependent: :restrict_with_exception

  validates :family_key, inclusion: { in: FAMILIES }, uniqueness: { scope: :workspace_id }
  validate :current_version_belongs_to_family

  def name
    FAMILIES.fetch(family_key)
  end

  private
    def current_version_belongs_to_family
      return unless current_version

      unless current_version.workspace_id == workspace_id && current_version.resolution_contract_family_id == id
        errors.add(:current_version, "does not belong to this Workspace and contract family")
      end
    end
end
