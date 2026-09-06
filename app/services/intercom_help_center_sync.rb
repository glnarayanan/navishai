class IntercomHelpCenterSync
  class Error < StandardError
    attr_reader :code
    def initialize(code)
      @code = code
      super(code.humanize)
    end
  end

  def self.sync!(connection:, client: IntercomClient.new(connection:), max_pages: 20, now: Time.current)
    new(connection, client, now).sync!(max_pages:)
  end

  def initialize(connection, client, now)
    @connection, @client, @now = connection, client, now
    @workspace = connection.workspace
  end

  def sync!(max_pages:)
    raise ArgumentError unless max_pages.in?(1..20)
    KnowledgeSyncPass.connection_pool.with_connection do |db|
      lock = db.select_value("SELECT pg_try_advisory_lock(61, #{Integer(@connection.id)})")
      return unless lock
      begin
        return unless enabled?
        @pass = @connection.knowledge_sync_passes.unfinished.first ||
          @connection.knowledge_sync_passes.create!(workspace: @workspace)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
        max_pages.times do
          break if @pass.enumerated? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise Error, "scan_limit" if @pass.page_count >= 1000
          page = @client.articles(starting_after: @pass.cursor)
          articles, cursor = parse_page(page)
          persist do
            articles.each { |article| observe!(article) }
            @pass.update!(cursor:, page_count: @pass.page_count + 1, enumerated: cursor.nil?, status: "pending", failure_code: nil)
          end
        end
        reconcile!(deadline) if @pass.enumerated?
        @pass
      rescue Error, IntercomClient::Error, KnowledgeIngestion::InvalidSource, ActiveRecord::RecordInvalid => error
        code = error.is_a?(Error) ? error.code : "unavailable"
        @pass&.update!(status: "failed", failure_code: code)
        raise Error, code
      ensure
        db.execute("SELECT pg_advisory_unlock(61, #{Integer(@connection.id)})")
      end
    end
  end

  private
    def enabled?
      @connection.reload.active? && @connection.help_center_sync_enabled? && @connection.connector_enabled? && !@workspace.reload.deletion_requested?
    end

    def persist
      @workspace.with_lock do
        raise Error, "sync_disabled" unless enabled?
        yield
      end
    end

    def parse_page(page)
      raise Error, "malformed_article" unless page.is_a?(Hash) && page["data"].is_a?(Array) && page["data"].size <= 50 && page["pages"].is_a?(Hash)
      next_page = page["pages"]["next"]
      cursor = next_page && next_page.is_a?(Hash) && next_page["starting_after"]
      if next_page && (!cursor.is_a?(String) || cursor.empty? || cursor.bytesize > 2048 || cursor == @pass.cursor)
        raise Error, "invalid_cursor"
      end
      [ page["data"], cursor || nil ]
    end

    def observe!(article)
      raise Error, "malformed_article" unless article.is_a?(Hash) && article["id"].is_a?(String) && article["id"].match?(/\A[a-zA-Z0-9_-]{1,100}\z/) && %w[published draft].include?(article["state"])
      return unless article["state"] == "published"
      title, body, updated = article.values_at("title", "body", "updated_at")
      raise Error, "malformed_article" unless title.is_a?(String) && title.length.in?(1..200) && body.is_a?(String) && updated.is_a?(Integer) && updated.positive? && updated <= @now.to_i + 300
      raise Error, "article_too_large" if body.bytesize > KnowledgeSourceVersion::MAX_CONTENT_BYTES
      text = "#{title}\n\n#{KnowledgeDocumentExtractor.extract(data: body, content_type: 'text/plain', filename: 'article.html').text}"
      raise Error, "article_too_large" if text.bytesize > KnowledgeSourceVersion::MAX_CONTENT_BYTES
      source = @connection.knowledge_sources.find_by(external_id: article["id"])
      return if source&.deleted_at
      observation = source&.knowledge_sync_observation
      if observation&.retired_at
        observation.update!(missing_passes: 0, unavailable_at: nil, retired_at: nil)
        audit!("knowledge.source_restored", source)
      end
      source = KnowledgeIngestion.ingest_integration!(
        workspace: @workspace, intercom_connection: @connection, source_kind: :intercom_help_center,
        title:, content: text, external_id: article["id"], source_updated_at: Time.at(updated),
        retrieved_at: @now, retrieved_from_url: article["url"]
      )
      observation ||= source.build_knowledge_sync_observation(workspace: @workspace)
      observation.update!(last_seen_pass: @pass, observed_at: @now, missing_passes: 0, unavailable_at: nil, retired_at: nil)
    end

    def reconcile!(deadline)
      candidates = @workspace.knowledge_sync_observations.joins(:knowledge_source)
        .where(knowledge_sources: { intercom_connection_id: @connection.id, deleted_at: nil })
        .where.not(last_seen_pass_id: @pass.id).where("knowledge_sync_observations.id > ?", @pass.reconciliation_position)
        .order(:id).limit(50)
      candidates.each do |observation|
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        article = begin
          @client.article(observation.knowledge_source.external_id)
        rescue IntercomClient::NotFound
          { "state" => "draft" }
        end
        persist do
          raise Error, "malformed_article" unless article.is_a?(Hash)
          if article["state"] == "published"
            observe!(article)
          elsif article["state"] == "draft"
            absent!(observation)
          else
            raise Error, "malformed_article"
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

    def absent!(observation)
      count = [ observation.missing_passes + 1, 2 ].min
      return if count == observation.missing_passes
      observation.update!(missing_passes: count, unavailable_at: observation.unavailable_at || @now, retired_at: count == 2 ? @now : nil)
      audit!(count == 1 ? "knowledge.source_stale" : "knowledge.source_retired", observation.knowledge_source)
    end

    def audit!(action, subject)
      AuditEvent.record!(action:, source: :integration, workspace: @workspace, actor_kind: :system, subject:)
    end
end
