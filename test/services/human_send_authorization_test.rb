require "test_helper"
require "pg"

class HumanSendAuthorizationTest < ActiveSupport::TestCase
  test "holds current role authority through the remote side effect" do
    workspace = workspaces(:acme_support)
    membership = memberships(:owner_support)
    Current.session = users(:owner).sessions.create!(authentication_method: :local, expires_at: 1.hour.from_now)
    change_blocked = false

    HumanSendAuthorization.with_current_authority(workspace:, membership:) do
      connection = PG.connect(dbname: ActiveRecord::Base.connection.current_database)
      connection.exec("SET lock_timeout = '100ms'")
      connection.exec_params("UPDATE memberships SET role = 'viewer' WHERE id = $1", [ membership.id ])
    rescue PG::LockNotAvailable
      change_blocked = true
    ensure
      connection&.close
    end

    assert change_blocked
    assert membership.reload.owner?
  end
end
