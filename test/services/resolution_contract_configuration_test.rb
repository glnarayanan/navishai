require "test_helper"
require "pg"
require "timeout"

class ResolutionContractConfigurationTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @families = ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    @support = @families.find { |family| family.family_key == "support_resolution" }
  end

  test "installs exactly one published low-risk version for each system family" do
    assert_equal ResolutionContractFamily::FAMILIES.keys.sort, @families.map(&:family_key).sort
    assert @families.all? { |family| family.versions.one? && family.current_version == family.versions.sole }
    assert @families.all? { |family| family.current_version.version_number == 1 }
    assert @families.all? { |family| family.current_version.missing_items_block? }
    assert @families.all? { |family| family.current_version.mandatory_review_checks == ResolutionContractVersion::REVIEW_CHECKS.keys.sort }
    assert @families.all? do |family|
      family.current_version.evidence_freshness_days == ResolutionContractConfiguration::DEFAULT_FRESHNESS_DAYS
    end

    assert_no_difference [ "ResolutionContractFamily.count", "ResolutionContractVersion.count" ] do
      ResolutionContractConfiguration.install_defaults!(workspace: @workspace)
    end
  end

  test "an Owner publishes one immutable bounded version with audit attribution" do
    current = @support.current_version
    attributes = attributes_for(current).merge(
      required_claim_categories: %w[customer_account_fact policy_entitlement],
      execution_budget_units: "75000",
      missing_items_block: "0"
    )

    assert_difference [ "ResolutionContractVersion.count", "AuditEvent.count" ], 1 do
      @published = ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: @support, attributes:
      )
    end

    assert_equal 2, @published.version_number
    assert_equal %w[customer_account_fact policy_entitlement], @published.required_claim_categories
    assert_equal 75_000, @published.execution_budget_units
    refute @published.missing_items_block?
    assert_equal @published, @support.reload.current_version
    assert_equal @owner.user, @published.created_by_user
    audit = AuditEvent.order(:id).last
    assert_equal "resolution_contract.published", audit.action
    assert_equal({
      "family" => "support_resolution", "from_version" => 1, "to_version" => 2
    }, audit.metadata)

    assert_raises(ActiveRecord::ReadOnlyRecord) { @published.update!(execution_budget_units: 1) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ResolutionContractVersion.transaction(requires_new: true) do
        ResolutionContractVersion.where(id: current.id).delete_all
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ResolutionContractVersion.transaction(requires_new: true) do
        ResolutionContractVersion.insert_all!([ {
          workspace_id: @workspace.id, resolution_contract_family_id: @support.id, version_number: 3,
          required_claim_categories: [ "arbitrary_rule" ],
          evidence_freshness_days: ResolutionContractConfiguration::DEFAULT_FRESHNESS_DAYS,
          mandatory_review_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort,
          execution_budget_units: 100_000, missing_items_block: true,
          created_at: Time.current, updated_at: Time.current
        } ])
      end
    end
  end

  test "stale publication invalid values roles and another Workspace fail closed" do
    current = @support.current_version
    attributes = attributes_for(current)
    member_user = User.create!(email_address: "contract-member@example.com", password: "password12345", verified_at: Time.current)
    member = @workspace.memberships.create!(user: member_user, role: :member)

    assert_raises(Current::RoleAccessDenied) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: member, family: @support, attributes:
      )
    end
    assert_raises(ResolutionContractConfiguration::InvalidConfiguration) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: @support,
        attributes: attributes.merge(required_claim_categories: [ "custom_expression" ])
      )
    end

    ResolutionContractConfiguration.publish!(
      workspace: @workspace, membership: @owner, family: @support,
      attributes: attributes.merge(execution_budget_units: "90000")
    )
    assert_raises(ResolutionContractConfiguration::StalePublication) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: @support,
        attributes: attributes.merge(execution_budget_units: "80000")
      )
    end

    foreign = ResolutionContractConfiguration.install_defaults!(workspace: workspaces(:beta_support)).first
    assert_raises(ActiveRecord::RecordNotFound) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: foreign,
        attributes: attributes_for(foreign.current_version)
      )
    end
  end

  test "published family row lock serializes concurrent version selection before the stale check" do
    database = ActiveRecord::Base.connection.current_database
    organization_id = workspaces(:acme_success).organization_id
    setup_connection = PG.connect(dbname: database)
    setup_connection.exec("BEGIN")
    workspace_id = setup_connection.exec_params(<<~SQL, [ organization_id, SecureRandom.uuid ]).first.fetch("id")
      INSERT INTO workspaces (organization_id, name, slug, runner_key, created_at, updated_at)
      VALUES ($1, 'Contract concurrency', 'contract-concurrency', $2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
    SQL
    family_id = setup_connection.exec_params(<<~SQL, [ workspace_id ]).first.fetch("id")
      INSERT INTO resolution_contract_families (workspace_id, family_key, created_at, updated_at)
      VALUES ($1, 'support_resolution', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
    SQL
    original_version_id = insert_contract_version(setup_connection, workspace_id, family_id, 1, 100_000)
    setup_connection.exec_params(
      "UPDATE resolution_contract_families SET current_version_id = $1 WHERE id = $2",
      [ original_version_id, family_id ]
    )
    setup_connection.exec("COMMIT")

    first_acquired = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    second_observed = Queue.new
    first = Thread.new do
      connection = PG.connect(dbname: database)
      connection.exec("BEGIN")
      connection.exec_params("SELECT id FROM resolution_contract_families WHERE id = $1 FOR UPDATE", [ family_id ])
      first_acquired << true
      release_first.pop
      version_id = insert_contract_version(connection, workspace_id, family_id, 2, 90_000)
      connection.exec_params(
        "UPDATE resolution_contract_families SET current_version_id = $1 WHERE id = $2",
        [ version_id, family_id ]
      )
      connection.exec("COMMIT")
    ensure
      connection&.close
    end
    first_acquired.pop

    second = Thread.new do
      connection = PG.connect(dbname: database)
      connection.exec("BEGIN")
      second_started << true
      row = connection.exec_params(
        "SELECT current_version_id FROM resolution_contract_families WHERE id = $1 FOR UPDATE",
        [ family_id ]
      ).first
      second_observed << row.fetch("current_version_id").to_i
      connection.exec("ROLLBACK")
    ensure
      connection&.close
    end
    second_started.pop

    assert_raises(Timeout::Error) { Timeout.timeout(0.1) { second_observed.pop } }
    release_first << true
    assert_not_equal original_version_id.to_i, Timeout.timeout(2) { second_observed.pop }
    first.join
    second.join
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
    setup_connection&.close
    delete_concurrency_workspace(database, workspace_id) if workspace_id
  end

  test "audit failure rolls back the version and published pointer" do
    current = @support.current_version
    original_record = AuditEvent.method(:record!)
    AuditEvent.define_singleton_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_raises(ResolutionContractConfiguration::InvalidConfiguration) do
      ResolutionContractConfiguration.publish!(
        workspace: @workspace, membership: @owner, family: @support,
        attributes: attributes_for(current).merge(execution_budget_units: "70000")
      )
    end
    assert_equal current, @support.reload.current_version
    assert_equal 1, @support.versions.count
  ensure
    AuditEvent.define_singleton_method(:record!, original_record) if original_record
  end

  private
    def insert_contract_version(connection, workspace_id, family_id, version_number, budget)
      values = [
        workspace_id, family_id, version_number,
        ResolutionContractConfiguration::DEFAULTS.fetch("support_resolution").fetch(:required_claim_categories).to_json,
        ResolutionContractConfiguration::DEFAULT_FRESHNESS_DAYS.to_json,
        ResolutionContractVersion::REVIEW_CHECKS.keys.sort.to_json,
        budget
      ]
      connection.exec_params(<<~SQL, values).first.fetch("id")
        INSERT INTO resolution_contract_versions (
          workspace_id, resolution_contract_family_id, version_number, required_claim_categories,
          evidence_freshness_days, mandatory_review_checks, execution_budget_units,
          missing_items_block, created_at, updated_at
        ) VALUES ($1, $2, $3, $4::jsonb, $5::jsonb, $6::jsonb, $7, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
      SQL
    end

    def delete_concurrency_workspace(database, workspace_id)
      connection = PG.connect(dbname: database)
      connection.exec_params("DELETE FROM workspaces WHERE id = $1", [ workspace_id ])
    ensure
      connection&.close
    end

    def attributes_for(version)
      {
        expected_current_version_id: version.id,
        required_claim_categories: version.required_claim_categories,
        evidence_freshness_days: version.evidence_freshness_days,
        mandatory_review_checks: version.mandatory_review_checks,
        execution_budget_units: version.execution_budget_units,
        missing_items_block: version.missing_items_block
      }
    end
end
