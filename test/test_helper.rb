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
  end
end
