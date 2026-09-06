require "test_helper"
require_relative "../test_helpers/zip_fixture_helper"

class KnowledgeWordDocumentTest < ActiveSupport::TestCase
  include ZipFixtureHelper

  test "extracts Word paragraphs, tables, breaks and notes without deleted text or field instructions" do
    body = "<w:p><w:r><w:t>Reset</w:t><w:tab/><w:t>password</w:t><w:br/><w:t>Now</w:t></w:r></w:p>" \
      "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>24 hours</w:t></w:r></w:p></w:tc></w:tr></w:tbl>" \
      "<w:del><w:r><w:t>Removed</w:t></w:r></w:del><w:p><w:r><w:instrText>PRIVATE FIELD</w:instrText></w:r></w:p>"
    data = word_document(body, extras: [ { name: "word/footnotes.xml", data: word_xml("<w:p><w:r><w:t>Note</w:t></w:r></w:p>") } ])
    assert KnowledgeWordDocument.document?(data)
    result = KnowledgeDocumentExtractor.extract(data:, content_type: KnowledgeWordDocument::CONTENT_TYPE, filename: "Guide.DOCX")
    assert_equal "docx", result.format
    assert_includes result.text, "Reset\tpassword\nNow"
    assert_includes result.text, "24 hours"
    assert_includes result.text, "Note"
    assert_not_includes result.text, "Removed"
    assert_not_includes result.text, "PRIVATE FIELD"
  end

  test "rejects malformed packages, duplicate names, macros, XML entities and embedded HTML" do
    malformed = "PK\x03\x04PK\x05\x06".b
    assert_not KnowledgeWordDocument.document?(malformed)
    assert_not KnowledgeWordDocument.document?(build_zip([ { name: "ordinary.txt", data: "hello" } ]))
    assert_not KnowledgeWordDocument.document?(word_document("", extras: [ { name: "word/vbaProject.bin", data: "macro" } ]))
    assert_not KnowledgeWordDocument.document?(word_document("", extras: [ { name: "word/document.xml", data: word_xml("") } ]))
    [ "<w:altChunk/>", "<w:p><w:r><w:t>&unknown;</w:t></w:r></w:p>" ].each do |body|
      assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) { KnowledgeWordDocument.extract(word_document(body)) }
    end
    document = word_xml("<w:p><w:r><w:t>&secret;</w:t></w:r></w:p>")
    document = '<!DOCTYPE document [<!ENTITY secret SYSTEM "file:///etc/passwd">]>' + document
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) { KnowledgeWordDocument.extract(word_document("", document:)) }
  end

  test "rejects empty and oversized extracted content and incorrect filename extensions" do
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) { KnowledgeWordDocument.extract(word_document("")) }
    data = word_document("<w:p><w:r><w:t>#{'x' * (KnowledgeSourceVersion::MAX_CONTENT_BYTES + 1)}</w:t></w:r></w:p>")
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) { KnowledgeWordDocument.extract(data) }
    assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data: word_document(""), content_type: KnowledgeWordDocument::CONTENT_TYPE, filename: "fake.txt")
    end
    error = assert_raises(KnowledgeDocumentExtractor::UnsupportedDocument) do
      KnowledgeDocumentExtractor.extract(data: "old word", content_type: "text/plain", filename: "guide.doc")
    end
    assert_includes error.message, "Save the document as .docx or PDF"
  end

  test "Word upload remains quarantined without scanning and passes through clean scanning" do
    data = word_document("<w:p><w:r><w:t>Retained</w:t></w:r></w:p>")
    prepared = AttachmentIntake.prepare!([ { filename: "guide.docx", data: } ])
    assert_equal "quarantined", prepared.sole.scan_status
    assert_equal KnowledgeWordDocument::CONTENT_TYPE, prepared.sole.content_type
    prepared.each(&:purge!)
    scanner = Object.new
    scanner.define_singleton_method(:scan) { |**| AttachmentScanner::Result.new(status: :clean, code: "clean") }
    prepared = AttachmentIntake.prepare!([ { filename: "guide.docx", data: } ], scanner:)
    assert_equal "available", prepared.sole.scan_status
    assert_equal data, prepared.sole.blob.download
  ensure
    prepared&.each(&:purge!)
  end

  private
    def word_xml(body)
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body + "</w:body></w:document>"
    end

    def word_document(body, extras: [], document: word_xml(body))
      build_zip([
        { name: "[Content_Types].xml", data: '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>' },
        { name: "word/document.xml", data: document },
        *extras
      ])
    end
end
