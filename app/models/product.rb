class Product < ApplicationRecord
  belongs_to :workspace
  has_many :knowledge_applicability_products, dependent: :restrict_with_exception
  has_many :support_case_products, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :workspace_id, case_sensitive: false }
end
