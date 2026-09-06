class WorkspaceConnector < ApplicationRecord
  PROVIDERS = %w[intercom notion].freeze

  belongs_to :workspace
  has_many :integration_user_connections, dependent: :destroy
  has_many :integration_oauth_attempts, dependent: :destroy
  encrypts :service_token

  validates :provider, inclusion: { in: PROVIDERS }, uniqueness: { scope: :workspace_id }
  validates :service_token, length: { maximum: 16_384 }, allow_nil: true

  def self.intercom_token(workspace:, remote_workspace_id:)
    connector = find_by(workspace:, provider: "intercom")
    return unless connector&.enabled? && connector.service_remote_workspace_id == remote_workspace_id

    connector.service_access_token
  end

  def service_access_token
    raise IntegrationOauth::Unavailable unless enabled? && workspace.deletion_requested_at.nil?

    service_token.presence || raise(IntegrationOauth::Unavailable)
  end
end
