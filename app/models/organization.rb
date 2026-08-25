class Organization < ApplicationRecord
  has_many :workspaces, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }
  normalizes :slug, with: ->(slug) { slug.strip.downcase }

  validates :name, presence: true, length: { maximum: 100 }
  validates :slug,
    presence: true,
    length: { maximum: 63 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: true
end
