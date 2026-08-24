class KnowledgeUrlFetcher < GuardedWebFetcher
  private
    def invalid_source!(message)
      raise KnowledgeIngestion::InvalidSource, message
    end

    def self.invalid_source!(message)
      raise KnowledgeIngestion::InvalidSource, message
    end
    private_class_method :invalid_source!
end
