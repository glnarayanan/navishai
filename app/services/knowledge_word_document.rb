class KnowledgeWordDocument
  CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  WORD_NAMESPACE = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  TYPES_NAMESPACE = "http://schemas.openxmlformats.org/package/2006/content-types"
  MAIN_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

  def self.document?(data)
    return false unless KnowledgeZipBundle.bundle?(data)

    parts(data)
    true
  rescue KnowledgeZipBundle::InvalidBundle, KnowledgeDocumentExtractor::UnsupportedDocument
    false
  end

  def self.extract(data)
    entries = parts(data)
    text = +""
    entries.select { |name, _| name.match?(%r{\Aword/(document|header\d+|footer\d+|footnotes|endnotes)\.xml\z}) }.each_value do |xml|
      document = parse(xml)
      raise KnowledgeDocumentExtractor::UnsupportedDocument, "The Word document contains unsupported embedded content." if document.at_xpath("//w:altChunk", "w" => WORD_NAMESPACE)

      document.xpath("//w:del", "w" => WORD_NAMESPACE).remove
      document.traverse do |node|
        next unless node.element? && node.namespace&.href == WORD_NAMESPACE

        case node.name
        when "t" then text << node.text
        when "tab", "tc" then text << "\t"
        when "br", "cr", "p", "tr" then text << "\n"
        end
        if text.bytesize > KnowledgeSourceVersion::MAX_CONTENT_BYTES
          raise KnowledgeDocumentExtractor::UnsupportedDocument, "The Word document exceeds the extracted text limit."
        end
      end
      text << "\n"
    end
    text = text.gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
    raise KnowledgeDocumentExtractor::UnsupportedDocument, "The Word document contains no extractable text." if text.empty?

    text
  rescue KnowledgeZipBundle::InvalidBundle => error
    raise KnowledgeDocumentExtractor::UnsupportedDocument, error.message
  end

  def self.parts(data)
    entries = KnowledgeZipBundle.entries(data, package: true).to_h { |entry| [ entry.filename, entry.data ] }
    types = parse(entries.fetch("[Content_Types].xml", ""))
    main = types.at_xpath("/t:Types/t:Override[@PartName='/word/document.xml']", "t" => TYPES_NAMESPACE)
    unless main&.[]("ContentType") == MAIN_TYPE && entries.key?("word/document.xml") && entries.keys.none? { |name| name.downcase.end_with?("vbaproject.bin") }
      raise KnowledgeDocumentExtractor::UnsupportedDocument, "The file is not a supported macro-free Word document."
    end
    entries
  end
  private_class_method :parts

  def self.parse(xml)
    document = Nokogiri::XML(xml) { |config| config.strict.nonet }
    raise KnowledgeDocumentExtractor::UnsupportedDocument, "Word documents cannot contain document type declarations." if document.internal_subset

    document
  rescue Nokogiri::XML::SyntaxError
    raise KnowledgeDocumentExtractor::UnsupportedDocument, "The Word document contains malformed XML."
  end
  private_class_method :parse
end
