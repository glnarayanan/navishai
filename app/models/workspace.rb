class Workspace < ApplicationRecord
  belongs_to :organization

  has_many :memberships, dependent: :restrict_with_exception
  has_many :users, through: :memberships

  normalizes :name, with: ->(name) { name.strip }
  normalizes :slug, with: ->(slug) { slug.strip.downcase }

  validates :name, presence: true, length: { maximum: 100 }
  validates :slug,
    presence: true,
    length: { maximum: 63 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: { scope: :organization_id }

  scope :accessible_to, ->(user) { joins(:memberships).where(memberships: { user: user }).distinct }
end
