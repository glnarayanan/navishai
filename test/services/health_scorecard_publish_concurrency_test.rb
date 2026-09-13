require "test_helper"

class HealthScorecardPublishConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(5)
    organization = Organization.create!(name: "Scorecard race #{suffix}", slug: "scorecard-race-#{suffix}")
    @workspace = organization.workspaces.create!(name: "Scorecard race", slug: "scorecard-race")
    user = User.create!(
      email_address: "scorecard-race-#{suffix}@example.com", password: "password12345", verified_at: Time.current
    )
    @owner = @workspace.memberships.create!(user:, role: :owner)
    @scorecard = HealthScorecardDesigner.install_default!(workspace: @workspace)
    @account = @workspace.accounts.create!(name: "Race account")
    @at = Time.zone.parse("2026-08-24 12:00:00")
    AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: @owner, at: @at)
  end

  teardown do
    next unless @workspace && Workspace.exists?(@workspace.id)

    tables = WorkspaceDeletion.send(:workspace_tables)
    Workspace.transaction do
      WorkspaceDeletion.send(:delete_workspace_records!, @workspace, tables)
    end
  end

  test "duplicate publish races keep one current version and remain idempotent" do
    version = propose
    preview = HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)
    original_id = @scorecard.current_version_id

    publications = race do
      HealthScorecardPublisher.publish!(
        workspace: Workspace.find(@workspace.id), membership: Membership.find(@owner.id),
        version: HealthScorecardVersion.find(version.id),
        expected_current_version_id: original_id, expected_backtest_id: preview.id
      )
    end

    assert publications.all?(HealthScorecardVersion)
    assert_equal [ version.id ], publications.map(&:id).uniq
    assert_equal version.id, @scorecard.reload.current_version_id
    assert_equal 1, @workspace.audit_events.where(
      action: "scorecard.published", subject_type: version.class.name, subject_id: version.id
    ).count
  end

  private
    def propose
      HealthScorecardDesigner.propose!(workspace: @workspace, membership: @owner,
        prompt: "Focus the score on clear renewal risk.", healthy_min: 75, watch_min: 50,
        weights: { "open_cases" => 40 })
    end

    def race(&block)
      ready = Queue.new
      release = Queue.new
      results = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            results << block.call
          rescue StandardError => error
            results << error
          end
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      threads.each do |thread|
        flunk "publish race thread did not finish" unless thread.join(10)
      end
      2.times.map { results.pop }
    end
end
