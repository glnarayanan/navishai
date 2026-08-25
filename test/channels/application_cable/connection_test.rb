require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects with an active session" do
    user = users(:owner)
    session = user.sessions.create!(authentication_method: :local, expires_at: 12.hours.from_now)
    cookies.signed[:session_id] = session.id

    connect

    assert_equal user, connection.current_user
  end

  test "rejects a revoked session" do
    session = users(:owner).sessions.create!(
      authentication_method: :local,
      expires_at: 12.hours.from_now,
      revoked_at: Time.current
    )
    cookies.signed[:session_id] = session.id

    assert_reject_connection { connect }
  end
end
