require "test_helper"

class PersonalProviderRevocationTest < ActiveSupport::TestCase
  test "downgrading a member disconnects their account before changing permissions" do
    membership = memberships(:teammate_success)
    account = PersonalProviderAccount.create!(workspace: membership.workspace, membership:, state: "connected")
    calls = []
    gateway = Object.new
    gateway.define_singleton_method(:account) do |**request|
      calls << request
      { "state" => "disconnected" }
    end
    with_gateway(gateway) { membership.update!(role: :viewer) }
    assert_equal "disconnect", calls.sole.fetch(:action)
    assert_equal membership.id, calls.sole.fetch(:membership_id)
    assert_equal membership.workspace.runner_key, calls.sole.fetch(:workspace_key)
    assert account.reload.disconnected?
    assert membership.reload.viewer?
  end

  test "failed account revocation prevents a permission change" do
    membership = memberships(:teammate_success)
    account = PersonalProviderAccount.create!(workspace: membership.workspace, membership:, state: "connected")
    gateway = Object.new
    gateway.define_singleton_method(:account) { |**| raise RunnerClient::Unavailable }
    with_gateway(gateway) do
      assert_raises(RunnerClient::Unavailable) { membership.update!(role: :viewer) }
    end
    assert_equal "manager", membership.reload.role
    assert account.reload.connected?
  end
  private
    def with_gateway(gateway)
      original = PersonalProviderGateway.method(:new)
      PersonalProviderGateway.define_singleton_method(:new) { gateway }
      yield
    ensure
      PersonalProviderGateway.define_singleton_method(:new, original)
    end
end
