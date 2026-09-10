class NotionKnowledgeSync
  def self.sync!(connection:, client: NotionKnowledgeClient.new(connection:), max_pages: 10, now: Time.current)
    new(connection, client, now).sync!(max_pages:)
  end

  def initialize(connection, client, now)
    @connection, @client, @now = connection, client, now
    @workspace = connection.workspace
  end

  def sync!(max_pages:)
    raise ArgumentError unless max_pages.in?(1..20)

    KnowledgeSyncPass.connection_pool.with_connection do |db|
      return unless db.select_value("SELECT pg_try_advisory_lock(62, #{Integer(@connection.id)})")

      begin
        return unless @connection.reload.ready?

        @pass = @connection.knowledge_sync_passes.unfinished.first ||
          @connection.knowledge_sync_passes.create!(workspace: @workspace, frontier: @connection.root_page_ids)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
        max_pages.times do
          break if @pass.enumerated? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise NotionKnowledgeClient::Error, "notion_scan_limit" if @pass.page_count >= 1000

          id = @pass.frontier.first
          document = begin
            @client.document(id)
          rescue NotionKnowledgeClient::Missing
            nil
          end
          persist do
            observe!(id, document) if document && !unavailable?(document.fetch(:metadata))
            visited = (@pass.visited + [ id ]).uniq
            frontier = (@pass.frontier.drop(1) + Array(document&.fetch(:children))).uniq - visited
            raise NotionKnowledgeClient::Error, "notion_scan_limit" if frontier.size + visited.size > 1000

            @pass.update!(frontier:, visited:, page_count: @pass.page_count + 1,
              enumerated: frontier.empty?, status: "pending", failure_code: nil)
          end
        end
        reconcile!(deadline) if @pass.enumerated?
        @pass
      rescue NotionKnowledgeClient::Error, KnowledgeIngestion::InvalidSource, ActiveRecord::RecordInvalid => error
        code = error.is_a?(NotionKnowledgeClient::Error) && error.message.match?(/\Anotion_[a-z_]+\z/) ? error.message : "notion_unavailable"
        @pass&.update!(status: "failed", failure_code: code)
        raise NotionKnowledgeClient::Error, code
      ensure
        db.execute("SELECT pg_advisory_unlock(62, #{Integer(@connection.id)})")
      end
    end
  end

  private
    def persist
      @workspace.with_lock do
        raise NotionKnowledgeClient::Error, "notion_disabled" unless @connection.reload.ready?

        yield
      end
    end

    def unavailable?(metadata)
      metadata["archived"] || metadata["in_trash"]
    end

    def observe!(id, document)
      metadata = document.fetch(:metadata)
      raise NotionKnowledgeClient::Error, "notion_malformed" unless metadata["id"] == id && metadata["properties"].is_a?(Hash)

      title_property = metadata["properties"].values.find { |value| value["type"] == "title" }
      title = Array(title_property&.fetch("title", nil)).map { |part| part.fetch("plain_text") }.join.presence || "Untitled"
      title = title.truncate(200)
      updated_at = Time.iso8601(metadata.fetch("last_edited_time"))
      raise NotionKnowledgeClient::Error, "notion_malformed" if updated_at > @now + 5.minutes

      source = @connection.knowledge_sources.find_by(external_id: id)
      return if source&.deleted_at

      observation = source&.knowledge_sync_observation
      if observation&.retired_at
        observation.update!(missing_passes: 0, unavailable_at: nil, retired_at: nil)
        audit!("knowledge.source_restored", source)
      end
      source = KnowledgeIngestion.ingest_integration!(workspace: @workspace, notion_knowledge_connection: @connection,
        source_kind: :notion_page, title:, content: "#{title}\n\n#{document.fetch(:text)}", external_id: id,
        source_updated_at: updated_at, retrieved_at: @now, retrieved_from_url: metadata["url"])
      observation ||= source.build_knowledge_sync_observation(workspace: @workspace)
      observation.update!(last_seen_pass: @pass, observed_at: @now, missing_passes: 0, unavailable_at: nil, retired_at: nil)
    rescue KeyError, TypeError, ArgumentError
      raise NotionKnowledgeClient::Error, "notion_malformed"
    end

    def reconcile!(deadline)
      candidates = KnowledgeSyncObservation.joins(:knowledge_source)
        .where(workspace: @workspace, knowledge_sources: { notion_knowledge_connection_id: @connection.id, deleted_at: nil })
        .where.not(last_seen_pass_id: @pass.id).where("knowledge_sync_observations.id > ?", @pass.reconciliation_position)
        .order(:id).limit(50)
      candidates.each do |observation|
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        persist do
          count = [ observation.missing_passes + 1, 2 ].min
          if count != observation.missing_passes
            observation.update!(missing_passes: count, unavailable_at: observation.unavailable_at || @now,
              retired_at: count == 2 ? @now : nil)
            audit!(count == 1 ? "knowledge.source_stale" : "knowledge.source_retired", observation.knowledge_source)
          end
          @pass.update!(reconciliation_position: observation.id)
        end
      end
      return if candidates.size == 50

      persist do
        @pass.update!(status: "completed", failure_code: nil, completed_at: @now)
        audit!("knowledge.sync_completed", @pass)
      end
    end

    def audit!(action, subject)
      AuditEvent.record!(action:, source: :integration, workspace: @workspace, actor_kind: :system, subject:)
    end
end
