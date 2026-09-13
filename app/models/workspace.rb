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
  has_many :notion_knowledge_connections, dependent: :restrict_with_exception
  has_many :workspace_connectors, dependent: :restrict_with_exception
  has_many :integration_user_connections, dependent: :restrict_with_exception
  has_many :integration_oauth_attempts, dependent: :restrict_with_exception
  has_many :knowledge_sync_passes, dependent: :restrict_with_exception
  has_many :knowledge_sync_observations, dependent: :restrict_with_exception
  has_many :products, dependent: :restrict_with_exception
  has_many :knowledge_applicabilities, dependent: :restrict_with_exception
  has_many :knowledge_applicability_products, dependent: :restrict_with_exception
  has_many :knowledge_applicability_connections, dependent: :restrict_with_exception
  has_many :support_case_products, dependent: :restrict_with_exception
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
  has_one :usage_rate_setting, dependent: :restrict_with_exception
  has_many :usage_rate_versions, dependent: :restrict_with_exception
  has_many :usage_cost_snapshots, dependent: :restrict_with_exception
  has_many :crew_artifacts, dependent: :restrict_with_exception
  has_many :resolution_contract_families, dependent: :restrict_with_exception
  has_many :resolution_contract_versions, dependent: :restrict_with_exception
  has_many :governed_policy_proposals, dependent: :restrict_with_exception
  has_many :governed_policy_subjects, dependent: :restrict_with_exception
  has_many :governed_policy_previews, dependent: :restrict_with_exception
  has_many :governed_policy_publications, dependent: :restrict_with_exception
  has_many :personal_provider_accounts, dependent: :restrict_with_exception
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
  has_many :intercom_connections, dependent: :restrict_with_exception
  has_many :intercom_conversation_links, dependent: :restrict_with_exception
  has_many :intercom_part_links, dependent: :restrict_with_exception
  has_many :intercom_tag_links, dependent: :restrict_with_exception
  has_many :intercom_webhook_deliveries, dependent: :restrict_with_exception
  has_many :intercom_sync_operations, dependent: :restrict_with_exception
  has_many :intercom_drafts, dependent: :restrict_with_exception
  has_many :intercom_outbound_deliveries, dependent: :restrict_with_exception
  has_many :intercom_backfill_manifests, dependent: :restrict_with_exception
  has_many :intercom_backfill_runs, dependent: :restrict_with_exception
  has_many :intercom_backfill_batches, dependent: :restrict_with_exception
  has_many :intercom_backfill_exceptions, dependent: :restrict_with_exception
  has_many :intercom_backfill_reports, dependent: :restrict_with_exception
  has_many :intercom_part_attachments, dependent: :restrict_with_exception
  has_many :account_health_inputs, dependent: :restrict_with_exception
  has_many :account_health_assessments, dependent: :restrict_with_exception
  has_many :account_health_signals, dependent: :restrict_with_exception
  has_many :account_risk_investigations, dependent: :restrict_with_exception
  has_many :customer_success_interventions, dependent: :restrict_with_exception
  has_many :customer_success_intervention_outcome_reviews, dependent: :restrict_with_exception
  has_many :operational_checks, dependent: :restrict_with_exception
  has_one :health_scorecard, dependent: :restrict_with_exception
  has_many :health_scorecard_versions, dependent: :restrict_with_exception
  has_many :health_scorecard_design_turns, dependent: :restrict_with_exception
  has_many :health_scorecard_backtests, dependent: :restrict_with_exception
  has_many :health_scorecard_proposals, dependent: :restrict_with_exception
  has_one :workspace_data_policy, dependent: :destroy
  has_many :workspace_content_expiry_runs, dependent: :restrict_with_exception
  has_many :notifications, dependent: :restrict_with_exception
  has_many :outbound_webhook_endpoints, dependent: :restrict_with_exception
  has_many :outbound_webhook_deliveries, dependent: :restrict_with_exception
  has_one :workspace_deletion_request, dependent: :destroy

  normalizes :name, with: ->(name) { name.strip }
  normalizes :slug, with: ->(slug) { slug.strip.downcase }

  validates :name, presence: true, length: { maximum: 100 }
  validates :web_search_provider_key, format: { with: RunnerProtocol::POLICY_KEY_PATTERN }, allow_nil: true
  validates :runner_key, presence: true, uniqueness: true
  validates :slug,
    presence: true,
    length: { maximum: 63 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ },
    uniqueness: { scope: :organization_id }

  after_create :install_default_crew_configuration
  after_create :install_default_resolution_contracts
  after_create :install_default_health_scorecard
  after_create :install_default_data_policy

  scope :accessible_to, ->(user) { joins(:memberships).where(memberships: { user: user }).distinct }
  scope :active, -> { where(deletion_requested_at: nil) }

  def deletion_requested?
    deletion_requested_at.present?
  end

  private
    def install_default_crew_configuration
      CrewConfiguration.install_defaults!(workspace: self)
    end

    def install_default_resolution_contracts
      ResolutionContractConfiguration.install_defaults!(workspace: self)
    end

    def install_default_health_scorecard
      HealthScorecardDesigner.install_default!(workspace: self)
    end

    def install_default_data_policy
      create_workspace_data_policy!
    end
end
