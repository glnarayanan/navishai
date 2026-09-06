require "zlib"

# Builds small ZIP archives in memory for tests without an archive dependency.
module ZipFixtureHelper
  def build_zip(entries, deflate: true)
    body = +"".b
    central = +"".b
    entries.each do |entry|
      name = entry.fetch(:name).b
      data = entry.fetch(:data).to_s.b
      method = entry.fetch(:method) { deflate ? 8 : 0 }
      payload = method == 8 ? raw_deflate(data) : data
      crc = Zlib.crc32(data)
      declared_size = entry.fetch(:declared_size, data.bytesize)
      offset = body.bytesize
      body << "PK\x03\x04".b << [ 20, 0, method, 0, 0, crc, payload.bytesize, declared_size, name.bytesize, 0 ].pack("vvvvvVVVvv") << name << payload
      external = entry.fetch(:symlink, false) ? (0o120777 << 16) : 0
      central << "PK\x01\x02".b <<
        [ 20, 20, 0, method, 0, 0, crc, payload.bytesize, declared_size, name.bytesize, 0, 0, 0, 0, external, offset ].pack("vvvvvvVVVvvvvvVV") <<
        name
    end
    directory_offset = body.bytesize
    body << central
    body << "PK\x05\x06".b << [ 0, 0, entries.size, entries.size, central.bytesize, directory_offset, 0 ].pack("vvvvVVv")
    body
  end

  private
    def raw_deflate(data)
      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      output = deflater.deflate(data, Zlib::FINISH)
      deflater.close
      output
    end
end
