class IntegrationOauthAttempt < ApplicationRecord
  belongs_to :workspace
  belongs_to :workspace_connector
  belongs_to :membership
  belongs_to :session

  def self.issue!(connector:, membership:, session:)
    raise IntegrationOauth::Unavailable unless connector.enabled? && connector.workspace_id == membership.workspace_id &&
      session.user_id == membership.user_id && session.revoked_at.nil? && !session.expired?

    state = SecureRandom.urlsafe_base64(32)
    where(expires_at: ...Time.current).delete_all
    create!(workspace: connector.workspace, workspace_connector: connector, membership:, session:,
      state_digest: Digest::SHA256.hexdigest(state), expires_at: 10.minutes.from_now)
    state
  end

  def self.consume!(state:, connector:, membership:, session:)
    raise IntegrationOauth::Unavailable unless state.is_a?(String) && state.bytesize.between?(32, 128)

    attempt = find_by!(state_digest: Digest::SHA256.hexdigest(state), workspace_connector: connector,
      workspace_id: membership.workspace_id, membership:, session:)
    attempt.with_lock do
      raise IntegrationOauth::Unavailable if attempt.consumed_at || attempt.expires_at <= Time.current ||
        !connector.reload.enabled? || session.revoked_at || session.expired? || session.user_id != membership.user_id

      attempt.update!(consumed_at: Time.current)
    end
    attempt
  end
end
