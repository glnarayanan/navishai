require "test_helper"

class CustomerSuccessInterventionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(5)
    organization = Organization.create!(name: "Follow-up race #{suffix}", slug: "follow-up-race-#{suffix}")
    @workspace = organization.workspaces.create!(name: "Follow-up race", slug: "follow-up-race")
    owner_user = User.create!(
      email_address: "follow-up-race-owner-#{suffix}@example.com",
      password: "password12345", verified_at: Time.current
    )
    member_user = User.create!(
      email_address: "follow-up-race-member-#{suffix}@example.com",
      password: "password12345", verified_at: Time.current
    )
    other_user = User.create!(
      email_address: "follow-up-race-other-#{suffix}@example.com",
      password: "password12345", verified_at: Time.current
    )
    @owner = @workspace.memberships.create!(user: owner_user, role: :owner)
    @member = @workspace.memberships.create!(user: member_user, role: :member)
    @other = @workspace.memberships.create!(user: other_user, role: :member)
    @account = @workspace.accounts.create!(name: "Race account")
    AccountDataImport.import_api!(
      workspace: @workspace, membership: @owner,
      rows: [ {
        source_id: "follow-up-race-#{suffix}",
        observed_at: Time.current.iso8601,
        account_name: @account.name,
        renewal_on: 40.days.from_now.to_date.iso8601,
        active_users: 40,
        licensed_seats: 50
      } ]
    )
    @assessment = @account.reload.current_health_assessment
    plan, = create_reviewed_intervention_plan(
      workspace: @workspace, account: @account, membership: @owner, assessment: @assessment
    )
    @intervention = propose_test_intervention(
      workspace: @workspace, account: @account, membership: @owner,
      accountable_membership: @member, assessment: @assessment, artifact: plan
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace: @workspace, membership: @owner, intervention: @intervention
    )
  end

  teardown do
    next unless @workspace && Workspace.exists?(@workspace.id)

    tables = WorkspaceDeletion.send(:workspace_tables)
    Workspace.transaction do
      WorkspaceDeletion.send(:delete_workspace_records!, @workspace, tables)
    end
  end

  test "concurrent reassignment and completion leave one authorized durable state" do
    results = race do |choice|
      if choice == :reassign
        CustomerSuccessInterventionWorkflow.reassign!(
          workspace: Workspace.find(@workspace.id),
          membership: Membership.find(@owner.id),
          intervention: CustomerSuccessIntervention.find(@intervention.id),
          accountable_membership: Membership.find(@other.id),
          reason: "Coverage moved during a concurrent completion attempt."
        )
      else
        CustomerSuccessInterventionWorkflow.complete!(
          workspace: Workspace.find(@workspace.id),
          membership: Membership.find(@member.id),
          intervention: CustomerSuccessIntervention.find(@intervention.id)
        )
      end
    end

    successes = results.reject { |result| result.is_a?(Exception) }
    denials = results.select { |result|
      result.is_a?(Current::RoleAccessDenied) ||
        result.is_a?(CustomerSuccessInterventionWorkflow::InvalidCommand)
    }
    assert_equal 1, successes.size
    assert_equal 1, denials.size

    record = @intervention.reload
    if record.completed?
      assert_equal @member.id, record.accountable_membership_id
      assert_equal @member.id, record.completed_by_membership_id
    else
      assert record.approved?
      assert_equal @other.id, record.accountable_membership_id
      assert_nil record.completed_by_membership_id
    end
  end

  private
    def race
      ready = Queue.new
      release = Queue.new
      results = Queue.new
      choices = [ :reassign, :complete ]
      threads = choices.map do |choice|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            results << yield(choice)
          rescue StandardError => error
            results << error
          end
        end
      end
      choices.size.times { ready.pop }
      choices.size.times { release << true }
      threads.each(&:join)
      choices.size.times.map { results.pop }
    end
end
