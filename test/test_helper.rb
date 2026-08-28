ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/helpdesk_test_helper"
require_relative "test_helpers/human_draft_test_helper"
require_relative "test_helpers/intervention_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all
    include HelpdeskTestHelper
    include HumanDraftTestHelper
    include InterventionTestHelper

    def approve_scripted_runtime(workspace:, membership:)
      installation = runtime_installations(:acme_scripted)
      installation.update!(
        approved: true, approved_by_membership: membership, approved_by_user: membership.user,
        approved_at: Time.current
      )
      installation
    end

    def create_governed_policy_canary(workspace:, membership:, support_case: nil)
      approve_scripted_runtime(workspace:, membership:)
      ResolutionContractConfiguration.install_defaults!(workspace:)
      CrewConfiguration.install_defaults!(workspace:)
      support_case ||= create_support_case(workspace:, membership:)
      family = workspace.resolution_contract_families.find_by!(family_key: "support_resolution")
      profile = workspace.agent_profiles.find_by!(role_key: "support_investigator")
      contract = family.current_version
      profile_version = profile.current_version
      proposal = GovernedPolicyChange.propose!(
        workspace:, membership:, family:, profile:, scope_kind: "support_case", scope_ids: [ support_case.id ],
        contract_attributes: {
          required_claim_categories: contract.required_claim_categories,
          evidence_freshness_days: contract.evidence_freshness_days,
          mandatory_review_checks: contract.mandatory_review_checks,
          execution_budget_units: contract.execution_budget_units - 1,
          missing_items_block: contract.missing_items_block
        },
        profile_attributes: {
          runtime_profile_key: profile_version.runtime_profile_key,
          fallback_profile_keys: profile_version.fallback_profile_keys,
          timeout_seconds: profile_version.timeout_seconds,
          max_steps: profile_version.max_steps,
          max_tool_calls: profile_version.max_tool_calls,
          review_policy: "on_policy_flag"
        },
        reason: "Bounded test canary"
      )
      preview = GovernedPolicyChange.preview!(workspace:, membership:, proposal:)
      publication = GovernedPolicyChange.publish!(workspace:, membership:, proposal:, preview:)
      [ proposal, preview, publication ]
    end
  end
end
