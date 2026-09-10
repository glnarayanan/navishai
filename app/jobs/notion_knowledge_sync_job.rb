class NotionKnowledgeSyncJob < ApplicationJob
  queue_as :default

  def perform(connection_id = nil)
    unless connection_id
      NotionKnowledgeConnection.where(enabled: true).find_each do |connection|
        self.class.perform_later(connection.id) if connection.ready?
      end
      return
    end

    connection = NotionKnowledgeConnection.find_by(id: connection_id)
    return unless connection&.ready?

    pass = NotionKnowledgeSync.sync!(connection:)
    self.class.set(wait: 5.seconds).perform_later(connection.id) if pass && !pass.completed_at
  rescue NotionKnowledgeClient::Error
    self.class.set(wait: 15.minutes).perform_later(connection_id)
  end
end
