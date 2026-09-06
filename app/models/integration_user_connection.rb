class IntegrationUserConnection < ApplicationRecord
  belongs_to :workspace
  belongs_to :workspace_connector
  belongs_to :membership
  encrypts :access_token, :refresh_token

  validates :membership_id, uniqueness: { scope: :workspace_connector_id }
  validates :remote_user_id, :remote_workspace_id, :access_token, presence: true
  validates :access_token, :refresh_token, length: { maximum: 16_384 }
  validates :remote_user_id, :remote_workspace_id, length: { maximum: 255 }
  validate :same_workspace

  def access_token_for!(actor)
    raise IntegrationOauth::Unavailable unless actor.id == membership_id && actor.workspace_id == workspace_id &&
      Membership.exists?(id: actor.id, workspace_id:, user_id: actor.user_id) &&
      workspace_connector.reload.enabled? && workspace.reload.deletion_requested_at.nil? && (expires_at.nil? || expires_at.future?)

    access_token
  end

  private
    def same_workspace
      errors.add(:workspace, "must match the connection and membership") unless
        workspace_connector&.workspace_id == workspace_id && membership&.workspace_id == workspace_id
    end
end
