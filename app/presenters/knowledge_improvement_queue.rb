class KnowledgeImprovementQueue
  DETAIL_LIMIT = 50
  REASON_ORDER = %w[deleted retired stale failed_sync].freeze

  Item = Data.define(:source, :reason, :label, :detail, :path)
  Improved = Data.define(:source, :prior_version, :current_version, :detail, :path)
  Count = Data.define(:key, :label, :value)

  attr_reader :items, :improved, :counts

  def self.build(workspace:)
    new(workspace:).tap(&:build)
  end

  def initialize(workspace:)
    @workspace = workspace
  end

  def build
    sources = @workspace.knowledge_sources.includes(
      :current_version, :versions, :knowledge_sync_observation, :intercom_connection, :notion_knowledge_connection
    )
    failed_intercom = failed_connection_ids(:intercom_connection_id)
    failed_notion = failed_connection_ids(:notion_knowledge_connection_id)
    @items = sources.filter_map { |source| item_for(source, failed_intercom, failed_notion) }
      .sort_by { |item| [ REASON_ORDER.index(item.reason), item.source.display_title, item.source.id ] }
      .first(DETAIL_LIMIT)
    attention_ids = items.map { |item| item.source.id }.to_set
    @improved = sources.filter_map { |source| improved_for(source, attention_ids) }
      .sort_by { |item| [ -item.current_version.version_number, item.source.display_title, item.source.id ] }
      .first(DETAIL_LIMIT)
    @counts = [
      Count.new(key: "attention", label: "Need attention", value: items.size),
      Count.new(key: "stale", label: "Stale", value: count_reason("stale")),
      Count.new(key: "deleted", label: "Deleted", value: count_reason("deleted")),
      Count.new(key: "retired", label: "Retired", value: count_reason("retired")),
      Count.new(key: "failed_sync", label: "Failed sync", value: count_reason("failed_sync")),
      Count.new(key: "improved", label: "Recently improved", value: improved.size)
    ]
    self
  end

  def attention?
    items.any?
  end

  private
    def count_reason(reason)
      items.count { |item| item.reason == reason }
    end

    def failed_connection_ids(column)
      @workspace.knowledge_sync_passes.where(status: "failed", completed_at: nil)
        .where.not(column => nil).distinct.pluck(column).to_set
    end

    def item_for(source, failed_intercom, failed_notion)
      observation = source.knowledge_sync_observation
      reason, label, detail = if observation&.retired_at.present?
        [ "retired", "Retired", "Two complete absences removed this source from current search." ]
      elsif source.deleted_at.present?
        [ "deleted", "Deleted", "A knowledge manager removed this source from current use." ]
      elsif source.stale?
        if observation&.unavailable_at.present?
          [ "stale", "Stale", "The last complete sync did not confirm this source." ]
        else
          [ "stale", "Stale", "The current version has expired." ]
        end
      elsif source.intercom_connection_id && failed_intercom.include?(source.intercom_connection_id)
        [ "failed_sync", "Sync failed", "The latest Help Center pass for this connection failed." ]
      elsif source.notion_knowledge_connection_id && failed_notion.include?(source.notion_knowledge_connection_id)
        [ "failed_sync", "Sync failed", "The latest Notion pass for this connection failed." ]
      end
      return unless reason

      Item.new(source:, reason:, label:, detail:, path: [ @workspace, source ])
    end

    def improved_for(source, attention_ids)
      return if attention_ids.include?(source.id)
      return unless source.left_improvement_queue?

      current = source.current_version
      prior = source.versions.find { |version| version.id != current.id && version.stale?(at: current.retrieved_at) }
      Improved.new(
        source:, prior_version: prior, current_version: current,
        detail: "Version #{prior.version_number} was stale. Version #{current.version_number} is current.",
        path: [ @workspace, source ]
      )
    end
end
