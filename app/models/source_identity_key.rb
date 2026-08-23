class SourceIdentityKey < ApplicationRecord
  KINDS = %w[email domain].freeze

  belongs_to :workspace
  belongs_to :source_identity

  enum :kind, KINDS.index_by(&:itself), validate: true

  validates :normalized_value, presence: true, length: { maximum: 254 }
  validate :workspace_matches_identity
  validate :kind_matches_entity

  scope :current, -> { where(retired_at: nil) }

  private
    def workspace_matches_identity
      return unless source_identity && workspace_id != source_identity.workspace_id

      errors.add(:workspace, "does not match source identity")
    end

    def kind_matches_entity
      return unless source_identity
      return if (source_identity.account? && domain?) || (source_identity.contact? && email?)

      errors.add(:kind, "does not match entity kind")
    end
end
