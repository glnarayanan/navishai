require "pdf-reader"
require "stringio"

# Turns an uploaded knowledge document into the plain-text snapshot the search
# index and citations use. Every format keeps the same bounds: at most
# KnowledgeSourceVersion::MAX_CONTENT_BYTES of text and, for PDFs, a fixed page
# budget so a hostile file cannot make a job spin. Extracted text is evidence,
# never instruction, and the original bytes stay on the retained attachment.
class KnowledgeDocumentExtractor
  class UnsupportedDocument < StandardError; end

  MAX_PDF_PAGES = 200
  TEXT_EXTENSIONS = %w[.txt .text .md .markdown].freeze
  HTML_EXTENSIONS = %w[.html .htm .xhtml].freeze
  PDF_EXTENSIONS = %w[.pdf].freeze
  SUPPORTED_EXTENSIONS = (TEXT_EXTENSIONS + HTML_EXTENSIONS + PDF_EXTENSIONS + %w[.docx .doc]).freeze

  Extracted = Data.define(:text, :format)

  def self.supported_filename?(filename)
    SUPPORTED_EXTENSIONS.include?(File.extname(filename.to_s).downcase)
  end

  def self.extract(data:, content_type:, filename:, workspace_key: nil)
    new.extract(data:, content_type:, filename:, workspace_key:)
  end

  def extract(data:, content_type:, filename:, workspace_key: nil)
    extension = File.extname(filename.to_s).downcase
    case content_type
    when "application/msword"
      raise UnsupportedDocument, "Legacy Word content must use a .doc filename." unless extension == ".doc"
      Extracted.new(text: KnowledgeDocumentGateway.new.extract_doc(data:, workspace_key:), format: "doc")
    when KnowledgeWordDocument::CONTENT_TYPE
      raise UnsupportedDocument, "Word content must use a .docx filename." unless extension == ".docx"
      Extracted.new(text: KnowledgeWordDocument.extract(data), format: "docx")
    when "application/pdf"
      raise UnsupportedDocument, "PDF content must use a .pdf filename." unless PDF_EXTENSIONS.include?(extension)
      Extracted.new(text: pdf_text(data), format: "pdf")
    when "text/plain"
      if HTML_EXTENSIONS.include?(extension)
        Extracted.new(text: html_text(data), format: "html")
      elsif TEXT_EXTENSIONS.include?(extension) || extension.empty?
        Extracted.new(text: utf8(data).gsub(/\r\n?/, "\n"), format: extension.start_with?(".m") ? "markdown" : "text")
      else
        raise UnsupportedDocument, "Upload a .txt, .md, .html, .pdf, .docx, or .doc file."
      end
    else
      raise UnsupportedDocument, "Upload a .txt, .md, .html, .pdf, .docx, or .doc file."
    end
  rescue RunnerClient::Error
    raise UnsupportedDocument, "We could not read this .doc file. Upload a .docx or PDF copy, or contact your admin."
  end

  private
    def utf8(data)
      data.to_s.dup.force_encoding(Encoding::UTF_8).scrub("�")
    end

    def html_text(data)
      document = Loofah.html5_document(utf8(data))
      document.scrub!(:prune)
      title = document.at_css("title")&.text.to_s.strip
      document.css("script, style, noscript, template, svg, head").each(&:remove)
      body = document.at_css("body") || document
      body.css("p, div, li, h1, h2, h3, h4, h5, h6, tr, br, section, article, blockquote, pre").each { |node| node.add_next_sibling("\n") }
      text = body.text.to_s
      text = "#{title}\n\n#{text}" if title.present? && !text.lstrip.start_with?(title)
      squeeze(text)
    end

    def pdf_text(data)
      reader = PDF::Reader.new(StringIO.new(data.to_s.b))
      raise UnsupportedDocument, "The PDF has no readable pages." if reader.page_count.zero?
      raise UnsupportedDocument, "The PDF exceeds the #{MAX_PDF_PAGES}-page limit." if reader.page_count > MAX_PDF_PAGES

      text = +""
      reader.pages.each do |page|
        text << utf8(page.text) << "\n\n"
        break if text.bytesize > KnowledgeSourceVersion::MAX_CONTENT_BYTES
      end
      raise UnsupportedDocument, "The PDF contains no extractable text." if text.strip.empty?

      squeeze(text)
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::EncryptedPDFError => error
      raise UnsupportedDocument, "The PDF could not be read (#{error.class.name.demodulize})."
    end

    def squeeze(text)
      text.gsub(/\r\n?/, "\n").gsub(/[ \t ]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
    end
end
