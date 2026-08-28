class IntercomBackfillManifest < ApplicationRecord
  STATUSES = %w[current consumed stale].freeze
  MAX_DISCOVERY_BYTES = 256.kilobytes

  belongs_to :workspace
  belongs_to :intercom_connection
  belongs_to :created_by_membership, class_name: "Membership"
  belongs_to :created_by_user, class_name: "User"
  has_one :intercom_backfill_run, dependent: :restrict_with_exception
  has_many :intercom_backfill_exceptions, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true
  validates :source_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :discovered_at, :expires_at, presence: true
  validate :bounded_data
  validate :records_stay_in_workspace

  def fresh?(at = Time.current) = current? && expires_at > at && expired_at.nil?

  private
    def bounded_data
      errors.add(:discovery_records, "is too large") if discovery_records.to_json.bytesize > MAX_DISCOVERY_BYTES
      errors.add(:counts, "is too large") if counts.to_json.bytesize > 8.kilobytes
    end

    def records_stay_in_workspace
      records = [ intercom_connection, created_by_membership ].compact
      errors.add(:base, "records belong to another workspace") if records.any? { |record| record.workspace_id != workspace_id }
      errors.add(:created_by_user, "does not match membership") unless created_by_membership&.user == created_by_user
    end
end
