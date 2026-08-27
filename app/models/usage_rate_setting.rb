class UsageRateSetting < ApplicationRecord
  belongs_to :workspace
  belongs_to :current_version, class_name: "UsageRateVersion", optional: true
  has_many :versions, -> { order(version_number: :desc) },
    class_name: "UsageRateVersion", dependent: :restrict_with_exception

  validates :workspace_id, uniqueness: true
end
