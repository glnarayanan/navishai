# Local echo peer, launched only inside disposable proof namespaces/containers.
require "socket"

server = TCPServer.new("::", Integer(ARGV.fetch(0)))
loop do
  socket = server.accept
  Thread.new(socket) do |client|
    while (line = client.gets)
      File.open(ARGV[1], "a", 0o600) { |file| file.puts(line) } if ARGV[1]
      client.write(line)
    end
  rescue SystemCallError, IOError
    nil
  ensure
    client.close
  end
end
