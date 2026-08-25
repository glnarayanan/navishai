require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    assert_difference "AuditEvent.count", 1 do
      post session_path, params: { email_address: @user.email_address, password: "password12345" }
    end

    assert_redirected_to root_path
    assert cookies[:session_id]
    event = AuditEvent.order(:id).last
    assert_equal "authentication.succeeded", event.action
    assert_equal @user, event.actor
    assert_equal({ "method" => "local" }, event.metadata)
  end

  test "create with invalid credentials" do
    assert_difference "AuditEvent.count", 1 do
      post session_path, params: { email_address: @user.email_address, password: "wrong" }
    end

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
    event = AuditEvent.order(:id).last
    assert event.anonymous?
    assert_not_includes event.metadata.to_json, "wrong"
  end

  test "create rejects an unverified user" do
    @user.update!(verified_at: nil)

    post session_path, params: { email_address: @user.email_address, password: "password12345" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "create rejects a break-glass user" do
    @user.update!(break_glass: true)

    post session_path, params: { email_address: @user.email_address, password: "password12345" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "create applies the shared authentication rate limit" do
    count = 0
    cache = Rails.cache
    cache.define_singleton_method(:increment) { |*| count += 1 }

    SecurityRateLimits::AUTHENTICATION.fetch(:to).times do
      post session_path, params: { email_address: @user.email_address, password: "wrong" }
      assert_redirected_to new_session_path
    end

    post session_path, params: { email_address: @user.email_address, password: "wrong" }
    assert_redirected_to new_session_path
    follow_redirect!
    assert_select ".flash-alert", text: /Try again later/
  ensure
    cache&.singleton_class&.remove_method(:increment)
  end

  test "destroy" do
    sign_in_as(User.take)

    assert_difference "AuditEvent.count", 1 do
      delete session_path
    end

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
    assert_equal "authentication.signed_out", AuditEvent.order(:id).last.action
  end
end
