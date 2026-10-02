require "pg"

module Navishai
  module DatabasePreflight
    class LegacyDatabase < StandardError; end

    LEGACY_TABLES = %w[
      account_health_assessments account_health_inputs account_health_signals account_merges account_risk_investigations accounts
      active_storage_attachments active_storage_blobs active_storage_variant_records agent_profile_versions agent_profiles
      case_notes case_slas contact_merges contacts conversation_message_attachments conversation_messages conversations
      crew_artifacts crew_task_dependencies crew_task_events crew_tasks crew_templates
      customer_success_intervention_due_notices customer_success_intervention_outcome_reviews customer_success_interventions
      email_draft_attachments email_drafts email_message_links email_threads execution_events execution_memory_selections execution_runs
      governed_policy_previews governed_policy_proposals governed_policy_publications governed_policy_subjects
      health_scorecard_backtests health_scorecard_design_turns health_scorecard_proposals health_scorecard_versions health_scorecards
      identity_match_candidates inbound_email_deliveries integration_oauth_attempts integration_user_connections
      intercom_backfill_batches intercom_backfill_exceptions intercom_backfill_manifests intercom_backfill_reports intercom_backfill_runs
      intercom_connections intercom_conversation_links intercom_drafts intercom_outbound_deliveries intercom_part_attachments intercom_part_links
      intercom_sync_operations intercom_tag_links intercom_webhook_deliveries
      knowledge_applicabilities knowledge_applicability_connections knowledge_applicability_products knowledge_improvement_candidates
      knowledge_source_versions knowledge_sources knowledge_sync_observations knowledge_sync_passes
      memory_correction_proposals memory_index_entries memory_proposals memory_records memory_tombstones notifications notion_knowledge_connections
      operational_checks outbound_email_deliveries outbound_email_delivery_attachments outbound_webhook_deliveries outbound_webhook_endpoints
      personal_provider_accounts products public_web_extractions public_web_search_results public_web_searches
      resolution_contract_families resolution_contract_versions runtime_installations service_calendar_holidays service_calendars
      shared_email_inboxes sla_escalation_tasks sla_policies source_identities source_identity_keys stored_attachments
      support_case_products support_case_status_changes support_case_taggings support_cases tags usage_cost_snapshots usage_rate_settings usage_rate_versions
      workspace_connectors workspace_content_expiry_runs workspace_data_policies workspace_deletion_requests workspace_tombstones
    ].freeze

    def self.verify!(database:, tables: [])
      if database.to_s.match?(/\Anavishai_(?:development|test|production)(?:_|\z)/) || (tables & LEGACY_TABLES).any?
        raise LegacyDatabase, "Refusing an old helpdesk database. Preserve/archive it and configure a fresh evaluation-lab database."
      end
    end

    def self.check_configurations!
      environments = Rails.env.development? ? %w[development test] : [ Rails.env ]
      ActiveRecord::Base.configurations.configs_for.select { |config| environments.include?(config.env_name) }.each do |config|
        settings = config.configuration_hash
        verify!(database: settings[:database])
        connection = PG.connect(settings.slice(:host, :port, :password).merge(
          dbname: settings[:database], user: settings[:username]))
        tables = connection.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map { |row| row["tablename"] }
        verify!(database: settings[:database], tables:)
      rescue PG::ConnectionBad => error
        # A missing fresh database is expected before db:create; other failures are not.
        raise unless error.message.include?("does not exist")
      ensure
        connection&.close
        connection = nil
      end
    end
  end
end
