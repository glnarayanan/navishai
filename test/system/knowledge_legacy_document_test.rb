require "application_system_test_case"

class KnowledgeLegacyDocumentSystemTest < ApplicationSystemTestCase
  setup do
    @previous_scanner = AttachmentScanner.default
    @original_gateway = KnowledgeDocumentGateway.method(:new)
    scanner = Object.new
    scanner.define_singleton_method(:scan) { |**| AttachmentScanner::Result.new(status: :clean, code: "clean") }
    AttachmentScanner.default = scanner
    gateway = Object.new
    gateway.define_singleton_method(:extract_doc) { |**| "Imported legacy document policy." }
    KnowledgeDocumentGateway.define_singleton_method(:new) { gateway }
  end

  teardown do
    AttachmentScanner.default = @previous_scanner
    KnowledgeDocumentGateway.define_singleton_method(:new, @original_gateway)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  test "legacy Word upload shows extracted knowledge and actionable converter failure" do
    sign_in(users(:owner))
    visit workspace_knowledge_sources_path(workspaces(:acme_support))
    reveal_setup "Add approved knowledge"
    select "Document upload", from: "Source type"
    fill_in "Title", with: "Legacy policy"
    assert_includes find_field("Document upload")[:accept], ".doc,"
    attach_file "Document upload", Rails.root.join("test/fixtures/files/knowledge-legacy.doc")
    click_button "Add knowledge source"
    assert_text "Knowledge source added."
    assert_text "Imported legacy document policy."
    assert_no_horizontal_overflow
    save_screenshot Rails.root.join("tmp/legacy-doc-success.png")

    gateway = Object.new
    gateway.define_singleton_method(:extract_doc) { |**| raise RunnerClient::Unavailable, "private details" }
    KnowledgeDocumentGateway.define_singleton_method(:new) { gateway }
    visit workspace_knowledge_sources_path(workspaces(:acme_support))
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 844, deviceScaleFactor: 1, mobile: true)
    reveal_setup "Add approved knowledge"
    select "Document upload", from: "Source type"
    fill_in "Title", with: "Unavailable converter"
    attach_file "Document upload", Rails.root.join("test/fixtures/files/knowledge-legacy.doc")
    click_button "Add knowledge source"
    assert_text "The isolated Word converter could not read this .doc file."
    assert_text "upload a .docx or PDF copy"
    assert_no_text "private details"
    assert_no_horizontal_overflow
    page.execute_script("arguments[0].scrollIntoView({behavior: 'instant', block: 'center'})", find(".inline-error"))
    save_screenshot Rails.root.join("tmp/legacy-doc-error-mobile.png")
  end
end
