class Account < ApplicationRecord
  belongs_to :workspace

  has_many :contacts, dependent: :restrict_with_exception
  has_many :crew_tasks, dependent: :restrict_with_exception
  has_many :source_identities, dependent: :restrict_with_exception
  has_many :source_merges, class_name: "AccountMerge", foreign_key: :source_id, dependent: :restrict_with_exception
  has_many :target_merges, class_name: "AccountMerge", foreign_key: :target_id, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }

  validates :name, presence: true, length: { maximum: 200 }

  def canonical
    source_merges.active.first&.target&.canonical || self
  end
end
