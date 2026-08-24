class Workspace < ApplicationRecord
  belongs_to :organization

  has_many :memberships, dependent: :restrict_with_exception
  has_many :users, through: :memberships
  has_many :workspace_invitations, dependent: :restrict_with_exception
  has_many :audit_events, dependent: :restrict_with_exception
  has_many :accounts, dependent: :restrict_with_exception
  has_many :contacts, dependent: :restrict_with_exception
  has_many :source_identities, dependent: :restrict_with_exception
  has_many :source_identity_keys, dependent: :restrict_with_exception
  has_many :identity_match_candidates, dependent: :restrict_with_exception
  has_many :account_merges, dependent: :restrict_with_exception
  has_many :contact_merges, dependent: :restrict_with_exception
  has_many :conversations, dependent: :restrict_with_exception
  has_many :conversation_messages, dependent: :restrict_with_exception
  has_many :support_cases, dependent: :restrict_with_exception
  has_many :support_case_status_changes, dependent: :restrict_with_exception
  has_many :tags, dependent: :restrict_with_exception
  has_many :support_case_taggings, dependent: :restrict_with_exception
  has_many :case_notes, dependent: :restrict_with_exception
  has_many :service_calendars, dependent: :restrict_with_exception
  has_many :service_calendar_holidays, dependent: :restrict_with_exception
  has_many :sla_policies, dependent: :restrict_with_exception
  has_many :case_slas, dependent: :restrict_with_exception
  has_many :sla_escalation_tasks, dependent: :restrict_with_exception
  has_many :shared_email_inboxes, dependent: :restrict_with_exception
  has_many :email_threads, dependent: :restrict_with_exception
  has_many :inbound_email_deliveries, dependent: :restrict_with_exception
  has_many :email_message_links, dependent: :restrict_with_exception

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
