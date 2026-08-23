require "test_helper"

class BreakGlassSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_token = ENV["NAVISHAI_BREAK_GLASS_TOKEN"]
    ENV["NAVISHAI_BREAK_GLASS_TOKEN"] = "a" * 32
  end

  teardown do
    ENV["NAVISHAI_BREAK_GLASS_TOKEN"] = @original_token
  end

  test "local break-glass user can sign in through the recovery route" do
    user = users(:owner)
    user.update!(break_glass: true)

    post break_glass_session_path, params: {
      deployment_token: "a" * 32,
      email_address: user.email_address,
      password: "password12345"
    }

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert_equal "break_glass", user.sessions.order(:created_at).last.authentication_method
    assert_operator user.sessions.order(:created_at).last.expires_at, :<=, 16.minutes.from_now
  end

  test "recovery route rejects an invalid deployment token" do
    user = users(:owner)
    user.update!(break_glass: true)

    post break_glass_session_path, params: {
      deployment_token: "wrong",
      email_address: user.email_address,
      password: "password12345"
    }

    assert_response :not_found
    assert_empty user.sessions
  end

  test "remote requests cannot reach recovery sign in" do
    host! "example.com"
    get new_break_glass_session_path, headers: { "REMOTE_ADDR" => "203.0.113.10" }

    assert_response :not_found
  end
end
