class IntercomHelpCenterSyncJob < ApplicationJob
  queue_as :background

  def self.enqueue_due
    IntercomConnection.active.where(help_center_sync_enabled: true).joins(:workspace)
      .merge(Workspace.active).find_each { |connection| perform_later(connection.id) }
  end

  def perform(connection_id)
    connection = IntercomConnection.find_by(id: connection_id)
    return unless connection
    pass = IntercomHelpCenterSync.sync!(connection:)
    self.class.set(wait: 5.seconds).perform_later(connection_id) if pass && !pass.completed_at
  rescue IntercomHelpCenterSync::Error
    # The pass retains its error and exact checkpoint for an operator retry.
  end
end
