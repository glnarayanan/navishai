require "test_helper"
require_relative "../test_helpers/zip_fixture_helper"

class KnowledgeLegacyDocumentTest < ActiveSupport::TestCase
  include ZipFixtureHelper

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @data = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1document".b
    @previous_scanner = AttachmentScanner.default
    @original_gateway = KnowledgeDocumentGateway.method(:new)
  end

  teardown do
    AttachmentScanner.default = @previous_scanner
    KnowledgeDocumentGateway.define_singleton_method(:new, @original_gateway)
  end

  test "clean scan precedes conversion and original document is retained" do
    calls = []
    scanner = Object.new
    scanner.define_singleton_method(:scan) do |**|
      calls << :scan
      AttachmentScanner::Result.new(status: :clean, code: "clean")
    end
    AttachmentScanner.default = scanner
    fake = Object.new
    workspace_key = @workspace.runner_key
    bytes = @data
    fake.define_singleton_method(:extract_doc) do |data:, workspace_key:|
      calls << [ :convert, workspace_key, data ]
      "Converted policy"
    end
    KnowledgeDocumentGateway.define_singleton_method(:new) { fake }
    source = upload
    assert_equal [ :scan, [ :convert, workspace_key, bytes ] ], calls
    assert_equal "Converted policy", source.current_version.content
    attachment = @workspace.stored_attachments.last
    assert_equal @data, attachment.file.download
    assert_equal "application/msword", attachment.detected_content_type
  end

  test "quarantine never invokes converter and failures purge prepared blobs" do
    KnowledgeDocumentGateway.define_singleton_method(:new) { raise "converter must not run" }
    AttachmentScanner.default = AttachmentScanner.new
    assert_no_difference [ "KnowledgeSource.count", "ActiveStorage::Blob.count" ] do
      assert_raises(KnowledgeIngestion::InvalidSource) { upload }
    end
    scanner = Object.new
    scanner.define_singleton_method(:scan) { |**| AttachmentScanner::Result.new(status: :clean, code: "clean") }
    AttachmentScanner.default = scanner
    fake = Object.new
    fake.define_singleton_method(:extract_doc) { |**| raise RunnerClient::Unavailable, "private runner details" }
    KnowledgeDocumentGateway.define_singleton_method(:new) { fake }
    assert_no_difference [ "KnowledgeSource.count", "ActiveStorage::Blob.count" ] do
      error = assert_raises(KnowledgeIngestion::InvalidSource) { upload }
      assert_includes error.message, "isolated Word converter"
      assert_not_includes error.message, "private runner details"
    end
  end

  test "OLE document requires doc extension" do
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data: @data, content_type: "application/msword", filename: "workbook.xls", workspace_key: @workspace.runner_key)
    end
    assert KnowledgeDocumentExtractor.supported_filename?("guide.DOC")
    entry = KnowledgeZipBundle.entries(build_zip([ { name: "guide.doc", data: @data } ])).sole
    assert_equal "guide.doc", entry.filename
    assert_equal @data, entry.data
  end

  private
    def upload
      KnowledgeIngestion.create!(workspace: @workspace, membership: @membership, source_kind: :upload,
        title: "Legacy policy", upload: { filename: "policy.doc", data: @data })
    end
end
