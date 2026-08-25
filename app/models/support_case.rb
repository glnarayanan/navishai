class SupportCase < ApplicationRecord
  STATUSES = %w[new triaged investigating waiting_customer waiting_internal draft_ready awaiting_human_review resolved closed].freeze
  PRIORITIES = %w[low normal high urgent].freeze

  belongs_to :workspace
  belongs_to :conversation
  belongs_to :assigned_membership, class_name: "Membership", optional: true

  has_many :status_changes, class_name: "SupportCaseStatusChange", dependent: :restrict_with_exception
  has_many :support_case_taggings, dependent: :restrict_with_exception
  has_many :tags, through: :support_case_taggings
  has_many :case_notes, dependent: :restrict_with_exception
  has_one :case_sla, dependent: :restrict_with_exception
  has_many :crew_tasks, dependent: :restrict_with_exception
  has_one :email_draft, dependent: :restrict_with_exception
  has_many :memory_records, dependent: :restrict_with_exception
  has_many :memory_proposals, dependent: :restrict_with_exception
  has_one :intercom_conversation_link, dependent: :restrict_with_exception
  has_one :intercom_draft, dependent: :restrict_with_exception

  enum :status, STATUSES.index_by(&:itself), validate: true, prefix: true
  enum :priority, PRIORITIES.index_by(&:itself), validate: true

  validates :status_changed_at, presence: true
  validate :terminal_timestamps_match_status

  private
    def terminal_timestamps_match_status
      expected_resolved_at = status == "resolved" || status == "closed"
      errors.add(:resolved_at, "does not match status") if expected_resolved_at != resolved_at.present?
      errors.add(:closed_at, "does not match status") if (status == "closed") != closed_at.present?
    end
end
