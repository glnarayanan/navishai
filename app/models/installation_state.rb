class InstallationState < ApplicationRecord
  validates :singleton, inclusion: { in: [ true ] }
end
