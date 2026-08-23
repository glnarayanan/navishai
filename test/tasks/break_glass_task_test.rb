require "test_helper"
require "rake"

class BreakGlassTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("navishai:break_glass:create")
    @task = Rake::Task["navishai:break_glass:create"]
    @original_environment = %w[ORGANIZATION_SLUG WORKSPACE_SLUG EMAIL PASSWORD].to_h { |key| [ key, ENV[key] ] }
  end

  teardown do
    @original_environment.each { |key, value| ENV[key] = value }
    @task.reenable
  end

  test "reset revokes sessions and limits recovery access to the selected workspace" do
    user = User.create!(
      email_address: "recovery@example.com",
      password: "old-password-123",
      password_confirmation: "old-password-123",
      verified_at: Time.current,
      break_glass: true
    )
    Membership.create!(workspace: workspaces(:beta_support), user: user, role: :admin)
    session = user.sessions.create!(authentication_method: :break_glass, expires_at: 15.minutes.from_now)
    ENV.update(
      "ORGANIZATION_SLUG" => "acme",
      "WORKSPACE_SLUG" => "support",
      "EMAIL" => user.email_address,
      "PASSWORD" => "new-password-123"
    )

    assert_difference "AuditEvent.count", 1 do
      @task.invoke
    end

    assert_predicate session.reload, :revoked_at?
    assert_equal [ workspaces(:acme_support) ], user.reload.workspaces
    assert user.memberships.sole.admin?
    event = AuditEvent.order(:id).last
    assert_equal "break_glass.configured", event.action
    assert_equal user, event.actor
    assert_equal workspaces(:acme_support), event.workspace
  end
end
