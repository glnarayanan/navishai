class SourceIdentity < ApplicationRecord
  ENTITY_KINDS = %w[account contact].freeze
  STATUSES = %w[pending ambiguous matched].freeze
  RESOLUTION_METHODS = %w[created deterministic reviewed].freeze
  NAMESPACE_FORMAT = /\A[a-z0-9]+(?:[._:-][a-z0-9]+)*\z/

  belongs_to :workspace
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  has_many :source_identity_keys, dependent: :restrict_with_exception
  has_many :identity_match_candidates, dependent: :restrict_with_exception

  enum :entity_kind, ENTITY_KINDS.index_by(&:itself), validate: true
  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :resolution_method, RESOLUTION_METHODS.index_by(&:itself), validate: { allow_nil: true }

  normalizes :source_namespace, with: ->(value) { value.strip.downcase }
  normalizes :source_record_type, with: ->(value) { value.strip.downcase }
  normalizes :source_record_id, with: ->(value) { value.strip }

  validates :source_namespace, presence: true, length: { maximum: 100 }, format: { with: NAMESPACE_FORMAT }
  validates :source_record_type, presence: true, length: { maximum: 100 }, format: { with: NAMESPACE_FORMAT }
  validates :source_record_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: %i[workspace_id source_namespace source_record_type] }
  validate :target_matches_entity_kind
  validate :target_stays_in_workspace

  def direct_record
    account || contact
  end

  def canonical_record
    direct_record&.canonical
  end

  def replace_keys!(keys)
    desired_keys = keys.to_h.flat_map do |kind, values|
      Array(values).map { |value| [ kind.to_s, IdentityKeyNormalizer.normalize(kind, value) ] }
    end.to_set

    transaction do
      lock!
      current_keys = source_identity_keys.current.index_by { |key| [ key.kind, key.normalized_value ] }
      current_keys.except(*desired_keys.to_a).each_value { |key| key.update!(retired_at: Time.current) }
      (desired_keys - current_keys.keys).each do |kind, value|
        source_identity_keys.create!(workspace: workspace, kind: kind, normalized_value: value)
      end
    end
  end

  private
    def target_matches_entity_kind
      expected = account? ? account : contact
      other = account? ? contact : account
      errors.add(:base, "target does not match entity kind") if other || (matched? && !expected)
    end

    def target_stays_in_workspace
      return unless direct_record && direct_record.workspace_id != workspace_id

      errors.add(:base, "target belongs to another workspace")
    end
end
