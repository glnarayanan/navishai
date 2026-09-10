require "test_helper"

class IntegrationOauthAttemptTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:owner_support)
    @connector = WorkspaceConnector.create!(workspace: @membership.workspace, provider: "notion", enabled: true)
    @session = @membership.user.sessions.create!(expires_at: 1.day.from_now, authentication_method: "local")
  end

  test "OAuth state is stored as a digest and accepted only once" do
    state = IntegrationOauthAttempt.issue!(connector: @connector, membership: @membership, session: @session)
    refute_equal state, IntegrationOauthAttempt.last.state_digest
    IntegrationOauthAttempt.consume!(state:, connector: @connector, membership: @membership, session: @session)
    assert_raises(IntegrationOauth::Unavailable) do
      IntegrationOauthAttempt.consume!(state:, connector: @connector, membership: @membership, session: @session)
    end
  end

  test "state cannot be used by a different session or after disable" do
    state = IntegrationOauthAttempt.issue!(connector: @connector, membership: @membership, session: @session)
    other = @membership.user.sessions.create!(expires_at: 1.day.from_now, authentication_method: "local")
    assert_raises(ActiveRecord::RecordNotFound) do
      IntegrationOauthAttempt.consume!(state:, connector: @connector, membership: @membership, session: other)
    end
    @connector.update!(enabled: false)
    assert_raises(IntegrationOauth::Unavailable) do
      IntegrationOauthAttempt.consume!(state:, connector: @connector, membership: @membership, session: @session)
    end
  end

  test "expired state cannot connect" do
    state = IntegrationOauthAttempt.issue!(connector: @connector, membership: @membership, session: @session)
    travel 11.minutes do
      assert_raises(IntegrationOauth::Unavailable) do
        IntegrationOauthAttempt.consume!(state:, connector: @connector, membership: @membership, session: @session)
      end
    end
  end
end
