class SourceRetentionJob < ApplicationJob
  def perform
    Source.where("expires_at <= ?", Time.current).find_each do |source|
      SourcePurge.call(source:)
    rescue ActiveRecord::RecordNotFound
      # Another deletion won the source lock.
      next
    end
  end
end
