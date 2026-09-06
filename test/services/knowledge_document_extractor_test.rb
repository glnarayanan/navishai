require "test_helper"

class KnowledgeDocumentExtractorTest < ActiveSupport::TestCase
  test "plain text and markdown are kept as text" do
    text = KnowledgeDocumentExtractor.extract(data: "Reset links expire.\r\nEscalate.", content_type: "text/plain", filename: "guide.txt")
    assert_equal "text", text.format
    assert_equal "Reset links expire.\nEscalate.", text.text

    markdown = KnowledgeDocumentExtractor.extract(data: "# Recovery\n\n- Step one\n- Step two", content_type: "text/plain", filename: "guide.md")
    assert_equal "markdown", markdown.format
    assert_equal "# Recovery\n\n- Step one\n- Step two", markdown.text
  end

  test "HTML keeps the title and readable text but drops scripts, styles, and markup" do
    html = <<~HTML
      <html><head><title>Password resets</title><style>p { color: red }</style></head>
      <body><h1>Password resets</h1><p>Links expire after <strong>24 hours</strong>.</p>
      <script>alert("ignore me")</script><ul><li>Escalate expired links</li><li>Never share links</li></ul>
      <a href="javascript:alert(1)">Click</a></body></html>
    HTML
    extracted = KnowledgeDocumentExtractor.extract(data: html, content_type: "text/plain", filename: "resets.html")

    assert_equal "html", extracted.format
    assert_includes extracted.text, "Password resets"
    assert_includes extracted.text, "Links expire after 24 hours."
    assert_includes extracted.text, "Escalate expired links\nNever share links"
    assert_not_includes extracted.text, "alert"
    assert_not_includes extracted.text, "color: red"
    assert_not_includes extracted.text, "<"
  end

  test "PDF text is extracted within the page budget and malformed PDFs fail closed" do
    data = file_fixture("guide.pdf").binread
    extracted = KnowledgeDocumentExtractor.extract(data:, content_type: "application/pdf", filename: "guide.pdf")
    assert_equal "pdf", extracted.format
    assert_includes extracted.text, "Reset links expire after 24 hours."
    assert_includes extracted.text, "Escalate expired links to the account owner."

    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data: "%PDF-1.4\ngarbage", content_type: "application/pdf", filename: "broken.pdf")
    end
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data:, content_type: "application/pdf", filename: "guide.txt")
    end
  end

  test "unsupported names and types are refused" do
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data: "text", content_type: "text/plain", filename: "script.js")
    end
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data: "\x89PNG".b, content_type: "image/png", filename: "image.png")
    end
    assert KnowledgeDocumentExtractor.supported_filename?("Notes/Playbook.PDF")
    assert_not KnowledgeDocumentExtractor.supported_filename?("archive.zip")
  end
end
