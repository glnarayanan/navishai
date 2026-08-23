require "test_helper"

class VerificationsControllerTest < ActionDispatch::IntegrationTest
  test "verifies a valid email token only after confirmation" do
    user = users(:teammate)
    user.update!(verified_at: nil)
    token = user.generate_token_for(:email_verification)

    get verification_path(token)

    assert_response :success
    assert_not user.reload.verified?

    patch verification_path(token)

    assert_redirected_to new_session_path
    assert user.reload.verified?
  end

  test "rejects an invalid token" do
    get verification_path("invalid")

    assert_redirected_to new_session_path
  end
end
