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

  test "a concurrent preview waits on the version lock held by publish" do
    version = propose
    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at)

    locked = Queue.new
    release = Queue.new
    results = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        HealthScorecard.transaction do
          HealthScorecard.find(@scorecard.id).lock!
          HealthScorecardVersion.find(version.id).lock!
          locked << true
          release.pop
        end
      end
    end

    locked.pop
    generator = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        HealthScorecardBacktest.connection.execute("SET lock_timeout TO '800ms'")
        results << HealthScorecardBacktester.run!(
          workspace: Workspace.find(@workspace.id), membership: Membership.find(@owner.id),
          version: HealthScorecardVersion.find(version.id), at: @at + 1.hour
        )
      rescue StandardError => error
        results << error
      ensure
        HealthScorecardBacktest.connection.execute("RESET lock_timeout")
      end
    end

    timeout = assert_kind_of ActiveRecord::LockWaitTimeout, wait_result(generator, results)
    assert_match(/lock timeout/i, timeout.message)
    release << true
    holder.join

    HealthScorecardBacktester.run!(workspace: @workspace, membership: @owner, version:, at: @at + 2.hours)
    assert_equal 2, version.backtests.count
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
    assert_equal 1, @workspace.audit_events.where(action: "scorecard.published", subject: version).count
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
      threads.each(&:join)
      2.times.map { results.pop }
    end

    def wait_result(thread, results)
      thread.join
      results.pop
    end
end
