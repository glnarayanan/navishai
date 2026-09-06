require "zlib"

# Reads a ZIP bundle of knowledge documents with the Ruby standard library only.
# It supports the stored and deflate methods, refuses anything that could escape
# or exhaust the importer (path traversal, absolute paths, symlinks, nested
# archives, oversized entries, too many entries), and returns each entry's bytes
# so every file passes the normal attachment scan and document extraction.
class KnowledgeZipBundle
  class InvalidBundle < StandardError; end

  SIGNATURE = "PK\x03\x04".b
  MAX_ENTRIES = 50
  MAX_PACKAGE_ENTRIES = 200
  MAX_ENTRY_BYTES = StoredAttachment::MAX_BYTES
  MAX_TOTAL_BYTES = 20.megabytes
  MAX_ARCHIVE_BYTES = 20.megabytes
  END_OF_CENTRAL_DIRECTORY = "PK\x05\x06".b
  CENTRAL_HEADER = "PK\x01\x02".b
  STORED = 0
  DEFLATED = 8
  SYMLINK_MODE = 0o120000

  Entry = Data.define(:filename, :data)

  def self.bundle?(data)
    data.to_s.b.start_with?(SIGNATURE)
  end

  def self.entries(data, package: false)
    new(data.to_s.b, package:).entries
  end

  def initialize(archive, package: false)
    raise InvalidBundle, "The ZIP bundle exceeds the 20 MiB limit." if archive.bytesize > MAX_ARCHIVE_BYTES
    raise InvalidBundle, "The file is not a ZIP bundle." unless archive.start_with?(SIGNATURE)

    @package = package
    @archive = archive
  end

  def entries
    directory = central_directory
    total = 0
    entries = directory.filter_map do |record|
      next if record[:directory]

      raise InvalidBundle, "The ZIP bundle contains an unsupported path #{record[:name].inspect}." unless safe_name?(record[:name])
      raise InvalidBundle, "The ZIP bundle contains a symbolic link." if record[:symlink]
      unless @package || KnowledgeDocumentExtractor.supported_filename?(record[:name])
        raise InvalidBundle, "#{record[:name]} is not a .txt, .md, .html, .pdf, or .docx file."
      end
      raise InvalidBundle, "#{record[:name]} exceeds the 5 MiB entry limit." if record[:size] > MAX_ENTRY_BYTES

      total += record[:size]
      raise InvalidBundle, "The ZIP bundle expands beyond the 20 MiB limit." if total > MAX_TOTAL_BYTES

      Entry.new(filename: record[:name], data: read_entry(record))
    end
    raise InvalidBundle, "The ZIP bundle contains no supported documents." if entries.empty?

    entries
  end

  private
    def central_directory
      tail_start = [ @archive.bytesize - 65_557, 0 ].max
      end_offset = @archive.rindex(END_OF_CENTRAL_DIRECTORY, tail_start.clamp(0, @archive.bytesize))
      end_offset = @archive.rindex(END_OF_CENTRAL_DIRECTORY) if end_offset.nil?
      raise InvalidBundle, "The ZIP bundle is truncated." if end_offset.nil?

      ending = @archive.byteslice(end_offset, 22)
      raise InvalidBundle, "The ZIP bundle is truncated." unless ending&.bytesize == 22
      disk, directory_disk, disk_count, count, directory_size, directory_offset, comment_size = ending.byteslice(4, 18).unpack("vvvvVVv")
      unless disk.zero? && directory_disk.zero? && disk_count == count && end_offset + 22 + comment_size == @archive.bytesize
        raise InvalidBundle, "The ZIP bundle end record is unsupported."
      end
      max_entries = @package ? MAX_PACKAGE_ENTRIES : MAX_ENTRIES
      raise InvalidBundle, "The ZIP bundle contains more than #{max_entries} entries." if count > max_entries
      raise InvalidBundle, "The ZIP bundle is truncated." if directory_offset + directory_size > end_offset

      records = []
      names = {}
      offset = directory_offset
      count.times do
        raise InvalidBundle, "The ZIP bundle directory is malformed." unless @archive.byteslice(offset, 4) == CENTRAL_HEADER

        # made-by, needed, flags, method, time, date, crc, compressed, size, name, extra, comment, disk, internal, external, offset
        header = @archive.byteslice(offset + 4, 42)
        raise InvalidBundle, "The ZIP bundle directory is truncated." unless header&.bytesize == 42
        fields = header.unpack("vvvvvvVVVvvvvvVV")
        method, crc, compressed_size, size = fields[3], fields[6], fields[7], fields[8]
        name_length, extra_length, comment_length = fields[9], fields[10], fields[11]
        external_attributes, local_offset = fields[14], fields[15]
        if offset + 46 + name_length + extra_length + comment_length > directory_offset + directory_size
          raise InvalidBundle, "The ZIP bundle directory is truncated."
        end
        name = @archive.byteslice(offset + 46, name_length).to_s.dup.force_encoding(Encoding::UTF_8)
        raise InvalidBundle, "The ZIP bundle contains an unsupported compression method." unless [ STORED, DEFLATED ].include?(method)

        raise InvalidBundle, "The ZIP bundle contains duplicate paths." if names[name]
        names[name] = true
        raise InvalidBundle, "The ZIP bundle contains encrypted entries." unless (fields[2] & 1).zero?

        records << {
          name:, method:, crc:, compressed_size:, size:, local_offset:,
          directory: name.end_with?("/"),
          symlink: ((external_attributes >> 16) & 0o170000) == SYMLINK_MODE
        }
        offset += 46 + name_length + extra_length + comment_length
      end
      records
    end

    def read_entry(record)
      header = @archive.byteslice(record[:local_offset], 30)
      raise InvalidBundle, "The ZIP bundle is malformed." unless header&.bytesize == 30 && header.start_with?(SIGNATURE)

      name_length, extra_length = header.byteslice(26, 4).unpack("vv")
      start = record[:local_offset] + 30 + name_length + extra_length
      compressed = @archive.byteslice(start, record[:compressed_size]).to_s
      raise InvalidBundle, "The ZIP bundle is truncated." if compressed.bytesize != record[:compressed_size]

      data = record[:method] == STORED ? compressed : inflate(compressed, record[:size])
      raise InvalidBundle, "#{record[:name]} does not match its declared size." unless data.bytesize == record[:size]
      raise InvalidBundle, "#{record[:name]} failed its integrity check." unless Zlib.crc32(data) == record[:crc]

      data
    end

    def inflate(compressed, expected_size)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      output = +"".b
      inflater.inflate(compressed) do |chunk|
        output << chunk
        raise InvalidBundle, "The ZIP bundle expands beyond its declared size." if output.bytesize > expected_size
      end
      output
    rescue Zlib::Error
      raise InvalidBundle, "The ZIP bundle is corrupt."
    ensure
      inflater&.close
    end

    def safe_name?(name)
      name.present? && name.valid_encoding? && !name.start_with?("/") && !name.match?(/\A[A-Za-z]:/) &&
        name.split("/").none? { |segment| segment.blank? || segment == ".." } && !name.include?("\0") && !name.include?("\\") && name.bytesize <= 255
    end
end
