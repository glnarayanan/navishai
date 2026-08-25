class Tag < ApplicationRecord
  belongs_to :workspace
  has_many :support_case_taggings, dependent: :restrict_with_exception
  has_many :support_cases, through: :support_case_taggings

  normalizes :name, with: ->(name) { name.strip }

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :workspace_id, case_sensitive: false }
end
