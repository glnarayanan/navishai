class IdentityMatchCandidate < ApplicationRecord
  belongs_to :workspace
  belongs_to :source_identity
  belongs_to :account, optional: true
  belongs_to :contact, optional: true

  enum :key_kind, SourceIdentityKey::KINDS.index_by(&:itself), validate: true

  validate :candidate_matches_identity
  validate :one_candidate

  def record
    account || contact
  end

  private
    def one_candidate
      errors.add(:base, "must name one candidate") unless [ account, contact ].compact.one?
    end

    def candidate_matches_identity
      return unless source_identity && record

      errors.add(:base, "candidate belongs to another workspace") if record.workspace_id != workspace_id || source_identity.workspace_id != workspace_id
      errors.add(:base, "candidate type does not match identity") if source_identity.account? != record.is_a?(Account)
    end
end
