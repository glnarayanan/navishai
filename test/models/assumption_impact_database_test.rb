require "test_helper"
require_relative "../test_helpers/assumption_impact_test_helper"

class AssumptionImpactDatabaseTest < ActiveSupport::TestCase
  include AssumptionImpactTestHelper
  setup { build_change_impact }

  test "SQL rejects foreign corpus source snapshots selected inputs and receipt lineage" do
    foreign = workspaces(:beta_support).corpora.create!(name: "Other private lab")
    with_impact_approval { @impact = request_impact }
    attributes = @impact.attributes.except("id").merge("request_key" => SecureRandom.uuid, "request_digest" => "a" * 64)
    assert_sql_refused { AssumptionImpact.insert_all!([ attributes.merge("state" => "running", "started_at" => Time.current) ]) }
    assert_sql_refused { AssumptionImpact.insert_all!([ attributes.merge("state" => "complete", "started_at" => Time.current, "finished_at" => Time.current) ]) }
    assert_sql_refused { AssumptionImpact.insert_all!([ attributes.merge("workspace_id" => foreign.workspace_id, "corpus_id" => foreign.id) ]) }
    assert_sql_refused { AssumptionImpact.insert_all!([ attributes.merge("after_snapshot_id" => @knowledge.source_snapshot_id) ]) }
    assert_sql_refused { AssumptionImpactResult.insert_all!([ { workspace_id: foreign.workspace_id, corpus_id: foreign.id, assumption_impact_id: @impact.id, result: { decision: "error" }, created_at: Time.current } ]) }
    assert_sql_refused { AssumptionImpactInput.insert_all!([ { workspace_id: foreign.workspace_id, corpus_id: foreign.id, assumption_impact_id: @impact.id, scenario_version_id: @version.id } ]) }
    assert_sql_refused { AssumptionImpactInput.insert_all!([ { workspace_id: @workspace.id, corpus_id: @corpus.id, assumption_impact_id: @impact.id, scenario_version_id: @scenarios.first.scenario_versions.order(:id).first.id } ]) }
  end

  test "SQL fixes request definition input membership once-only claim and terminal results" do
    with_impact_response do
      @impact = request_impact
      assert_sql_refused { AssumptionImpact.where(id: @impact.id).update_all(input: {}) }
      assert_sql_refused { AssumptionImpact.where(id: @impact.id).update_all(configuration: {}) }
      assert_sql_refused { AssumptionImpact.where(id: @impact.id).update_all(state: "complete", started_at: Time.current, finished_at: Time.current) }
      assert_sql_refused { AssumptionImpactResult.insert_all!([ { workspace_id: @workspace.id, corpus_id: @corpus.id, assumption_impact_id: @impact.id, result: { decision: "error" }, created_at: Time.current } ]) }
      assert_sql_refused { AssumptionImpactInput.where(assumption_impact: @impact).update_all(scenario_version_id: @version.id) }
      AssumptionImpactJob.perform_now(@impact.id)
      assert_equal "complete", @impact.reload.state
      assert_sql_refused { AssumptionImpact.where(id: @impact.id).update_all(state: "queued", started_at: nil, finished_at: nil) }
      assert_sql_refused { AssumptionImpact.where(id: @impact.id).update_all(error: "rewrite history") }
      assert_sql_refused { AssumptionImpactResult.where(assumption_impact: @impact).update_all(result: { decision: "abstain" }) }
      assert_sql_refused { AssumptionImpactInput.insert_all!([ { workspace_id: @workspace.id, corpus_id: @corpus.id, assumption_impact_id: @impact.id, scenario_version_id: @version.id } ]) }
    end
  end

  test "SQL cannot finish a running claim without a result" do
    with_impact_approval do
      impact = request_impact
      impact.update!(state: "running", started_at: Time.current)
      assert_sql_refused { AssumptionImpact.where(id: impact.id).update_all(state: "complete", finished_at: Time.current) }
      assert_equal "running", impact.reload.state
    end
  end

  test "restricted runtime DML and sequence grants support the new lifecycle but cannot rewrite or disable guards" do
    connection = ActiveRecord::Base.connection
    role = connection.quote_column_name("impact_test_#{SecureRandom.hex(8)}")
    # Role and grants roll back with the test transaction; no deployed role changes.
    connection.execute("CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS")
    connection.execute("GRANT USAGE ON SCHEMA public TO #{role}")
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{role}")
    connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{role}")
    connection.execute("SET LOCAL ROLE #{role}")
    assert_equal false, connection.select_value("SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
    with_impact_response do
      impact = request_impact
      AssumptionImpactJob.perform_now(impact.id)
      assert_equal "complete", impact.reload.state
      assert_sql_refused { AssumptionImpactResult.where(assumption_impact: impact).update_all(result: {}) }
      assert_sql_refused { connection.execute("ALTER TABLE assumption_impacts DISABLE TRIGGER ALL") }
      SourcePurge.call(source: @source, membership: @membership)
      assert_not AssumptionImpact.exists?(impact.id)
      assert_not AssumptionImpactResult.exists?(assumption_impact_id: impact.id)
    end
  ensure
    connection&.execute("RESET ROLE")
  end

  private
    def assert_sql_refused
      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) { yield }
      end
    end
end
