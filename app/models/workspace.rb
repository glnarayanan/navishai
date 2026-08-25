class Workspace < ApplicationRecord
  attribute :runner_key, default: -> { SecureRandom.uuid }

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
  has_many :email_drafts, dependent: :restrict_with_exception
  has_many :outbound_email_deliveries, dependent: :restrict_with_exception
  has_many :stored_attachments, dependent: :restrict_with_exception
  has_many :conversation_message_attachments, dependent: :restrict_with_exception
  has_many :email_draft_attachments, dependent: :restrict_with_exception
  has_many :outbound_email_delivery_attachments, dependent: :restrict_with_exception
  has_many :knowledge_sources, dependent: :restrict_with_exception
  has_many :knowledge_source_versions, dependent: :restrict_with_exception
  has_many :crew_templates, dependent: :restrict_with_exception
  has_many :agent_profiles, dependent: :restrict_with_exception
  has_many :agent_profile_versions, dependent: :restrict_with_exception
  has_many :crew_tasks, dependent: :restrict_with_exception
  has_many :crew_task_events, dependent: :restrict_with_exception
  has_many :crew_task_dependencies, dependent: :restrict_with_exception
  has_many :execution_runs, dependent: :restrict_with_exception
  has_many :execution_events, dependent: :restrict_with_exception
  has_many :crew_artifacts, dependent: :restrict_with_exception
  has_many :runtime_installations, dependent: :restrict_with_exception
  has_many :public_web_searches, dependent: :restrict_with_exception
  has_many :public_web_search_results, dependent: :restrict_with_exception
  has_many :public_web_extractions, dependent: :restrict_with_exception
  has_many :memory_records, dependent: :restrict_with_exception
  has_many :memory_index_entries, dependent: :restrict_with_exception
  has_many :memory_proposals, dependent: :restrict_with_exception
  has_many :execution_memory_selections, dependent: :restrict_with_exception
  has_many :memory_correction_proposals, dependent: :restrict_with_exception
  has_many :memory_tombstones, dependent: :restrict_with_exception

  normalizes :name, with: ->(name) { name.strip }
  normalizes :slug, with: ->(slug) { slug.strip.downcase }

  validates :name, presence: true, length: { maximum: 100 }
  validates :runner_key, presence: true, uniqueness: true
  validates :slug,
    presence: true,
    length: { maximum: 63 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: { scope: :organization_id }

  after_create :install_default_crew_configuration

  scope :accessible_to, ->(user) { joins(:memberships).where(memberships: { user: user }).distinct }

  private
    def install_default_crew_configuration
      CrewConfiguration.install_defaults!(workspace: self)
    end
end
