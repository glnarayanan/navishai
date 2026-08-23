require "test_helper"

class VerificationsControllerTest < ActionDispatch::IntegrationTest
  test "verifies a valid email token only after confirmation" do
    user = users(:teammate)
    user.update!(verified_at: nil)
    token = user.generate_token_for(:email_verification)

    get verification_path(token: token)

    assert_response :success
    assert_not user.reload.verified?

    assert_difference "AuditEvent.count", 1 do
      patch verification_path(token: token)
    end

    assert_redirected_to new_session_path
    assert user.reload.verified?
    assert_equal "email_verification.completed", AuditEvent.order(:id).last.action

    assert_no_difference "AuditEvent.count" do
      patch verification_path(token: token)
    end
    assert_redirected_to new_session_path
  end

  test "rejects an invalid token" do
    get verification_path(token: "invalid")

    assert_redirected_to new_session_path
  end
end
