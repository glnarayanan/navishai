require "uri"

class PublicWebExtraction < ApplicationRecord
  STATUSES = %w[extracting completed failed].freeze

  belongs_to :workspace
  belongs_to :public_web_search_result
  belongs_to :requested_by_membership, class_name: "Membership"
  belongs_to :requested_by_user, class_name: "User"

  enum :status, STATUSES.index_with(&:itself)

  validates :request_key, presence: true, length: { maximum: 128 },
    format: { with: /\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/ }, uniqueness: { scope: :workspace_id }
  validates :status, inclusion: { in: STATUSES }
  validates :source_url, presence: true, length: { maximum: 2_048 }
  validates :final_url, length: { maximum: 2_048 }, allow_nil: true
  validates :content, length: { maximum: 1.megabyte }, allow_nil: true
  validates :content_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :failure_code, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }, allow_nil: true
  validate :assignment_is_consistent
  validate :result_is_consistent
  validate :urls_are_safe

  private
    def assignment_is_consistent
      return if workspace.nil? || public_web_search_result.nil? || requested_by_membership.nil? || requested_by_user.nil?

      unless public_web_search_result.workspace_id == workspace_id && requested_by_membership.workspace_id == workspace_id &&
          requested_by_membership.user_id == requested_by_user_id
        errors.add(:workspace, "does not match the result and actor")
      end
    end

    def result_is_consistent
      valid = case status
      when "extracting"
        final_url.nil? && content.nil? && content_digest.nil? && failure_code.nil? && retrieved_at.nil? && source_updated_at.nil?
      when "completed"
        final_url.present? && content.present? && content_digest.present? && failure_code.nil? && retrieved_at.present?
      when "failed"
        final_url.nil? && content.nil? && content_digest.nil? && failure_code.present? && retrieved_at.nil? && source_updated_at.nil?
      end
      errors.add(:status, "does not match the extraction result") unless valid
    end

    def urls_are_safe
      [ [ :source_url, source_url ], [ :final_url, final_url ] ].each do |attribute, value|
        next if value.nil?

        uri = URI.parse(value)
        unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
          errors.add(attribute, "must be an HTTPS URL without credentials or a fragment")
        end
      rescue URI::InvalidURIError
        errors.add(attribute, "must be a valid HTTPS URL")
      end
    end
end
