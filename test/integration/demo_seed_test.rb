require "test_helper"

class DemoSeedTest < ActiveSupport::TestCase
  test "creates one repeatable demonstration workspace through product services" do
    original_seed_demo = ENV["NAVISHAI_SEED_DEMO"]
    ENV["NAVISHAI_SEED_DEMO"] = "1"
    load Rails.root.join("db/seeds.rb")

    workspace = Organization.find_by!(slug: "navishai-demo").workspaces.find_by!(slug: "customer-operations")
    counts = [ workspace.support_cases.count, workspace.audit_events.count, workspace.memory_records.count ]

    load Rails.root.join("db/seeds.rb")

    assert_equal counts, [ workspace.support_cases.count, workspace.audit_events.count, workspace.memory_records.count ]
    assert_equal 2, workspace.support_cases.count
    assert_equal %w[investigating waiting_customer], workspace.support_cases.order(:id).pluck(:status)
    assert_equal "urgent", workspace.support_cases.order(:id).first.priority
    assert_equal 2, workspace.health_scorecard.current_version.version_number
    assert workspace.account_risk_investigations.exists?
    assert workspace.memory_records.exists?
    assert workspace.audit_events.exists?(action: "scorecard.published")
  ensure
    ENV["NAVISHAI_SEED_DEMO"] = original_seed_demo
  end
end
