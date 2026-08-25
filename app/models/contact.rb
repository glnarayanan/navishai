class Contact < ApplicationRecord
  belongs_to :workspace
  belongs_to :account, optional: true

  has_many :source_identities, dependent: :restrict_with_exception
  has_many :source_merges, class_name: "ContactMerge", foreign_key: :source_id, dependent: :restrict_with_exception
  has_many :target_merges, class_name: "ContactMerge", foreign_key: :target_id, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }

  validates :name, length: { maximum: 200 }, allow_nil: true
  validate :account_stays_in_workspace

  def canonical
    source_merges.active.first&.target&.canonical || self
  end

  private
    def account_stays_in_workspace
      return unless account && account.workspace_id != workspace_id

      errors.add(:account, "must belong to the same workspace")
    end
end
