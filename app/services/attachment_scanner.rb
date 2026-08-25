class AttachmentScanner
  Result = Data.define(:status, :code)

  class << self
    attr_writer :default

    def default
      @default ||= new
    end
  end

  def scan(data:, content_type:, filename:)
    Result.new(status: :unavailable, code: "scanner_unavailable")
  end
end
