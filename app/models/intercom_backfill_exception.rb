class IntercomBackfillException < ApplicationRecord
  KINDS = %w[ambiguous_identity source_changed unsupported_field attachment_rejected attachment_unavailable persistence_failed].freeze
  RECOVERY_ACTIONS = %w[review_identity restart_preview inspect_source inspect_attachment resume].freeze
  MAX_DETAIL_BYTES = 500

  belongs_to :workspace
  belongs_to :intercom_backfill_manifest
  belongs_to :intercom_backfill_run, optional: true
  belongs_to :source_identity, optional: true

  enum :status, %w[open resolved].index_by(&:itself), validate: true
  validates :exception_kind, inclusion: { in: KINDS }
  validates :recovery_action, inclusion: { in: RECOVERY_ACTIONS }
  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :remote_record_id, length: { in: 1..255 }
  validates :detail, length: { in: 1..MAX_DETAIL_BYTES }
end
