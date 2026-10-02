#!/usr/bin/env ruby
# Real Compose normalization and kernel binds, never the host network or a VPS.
require "json"
require "open3"
require "rbconfig"
require "shellwords"

abort "Usage: ruby test/support/vps_ingress_proof.rb VERIFIED_COMPOSE_BINARY [VPS_COMPOSE_FILE]" unless (1..2).cover?(ARGV.length)
root = File.expand_path("../..", __dir__)
compose = File.expand_path(ARGV.fetch(0))
override = File.expand_path(ARGV[1] || File.join(root, "ops/vps/compose.yaml"))
environment = { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"),
  "VPS_IMAGE" => "navishai-reset:proof", "NAVISHAI_APP_HOST" => "proof.example.invalid",
  "NAVISHAI_ACME_EMAIL" => "proof@example.invalid", "NAVISHAI_PUBLIC_LISTEN_ADDRESS" => "auto", "VPS_PUBLIC_LISTEN_ADDRESS" => "203.0.113.9",
  "NAVISHAI_DATABASE_PASSWORD" => "a" * 48, "NAVISHAI_POSTGRES_PASSWORD" => "b" * 48,
  "NAVISHAI_PREPARE_PASSWORD" => "c" * 48, "NAVISHAI_SECRET_KEY_BASE" => "d" * 96 }
output, error, status = Open3.capture3(environment, compose, "--project-name", "navishai-reset", "--project-directory", root,
  "--file", File.join(root, "compose.yaml"), "--file", override, "config", "--format", "json", unsetenv_others: true)
abort error unless status.success?
services = JSON.parse(output).fetch("services")
%w[web jobs].each do |service|
  runtime = services.fetch(service)
  abort "Runtime namespace changed" unless runtime.fetch("network_mode") == "service:app-net" && !runtime.key?("networks") && !runtime.key?("ports")
end
ports = services.fetch("proxy").fetch("ports")
kernel = <<~'RUBY'
  ports = JSON.parse(ARGV.fetch(0))
  cli = ARGV.fetch(1)
  sockets = []
  begin
    sockets << TCPServer.new("100.98.160.115", 443)
    sockets << TCPServer.new("fd7a:115c:a1e0::6634:a074", 443)
    TCPSocket.new("100.98.160.115", 443).close
    TCPSocket.new("fd7a:115c:a1e0::6634:a074", 443).close
    begin
      socket = TCPServer.new("0.0.0.0", 443)
      socket.close
      abort "Wildcard unexpectedly coexists with tailnet listener"
    rescue Errno::EADDRINUSE
      puts "RED reproduced: wildcard :443 fails with tailnet-only listener"
    end
    check = "source #{Shellwords.escape(cli)}; NAVISHAI_PUBLIC_LISTEN_ADDRESS=auto; vps_ingress_check; [[ $VPS_PUBLIC_LISTEN_ADDRESS == 203.0.113.9 ]]"
    output, status = Open3.capture2e("bash", "-euo", "pipefail", "-c", check)
    abort output unless status.success?
    ports.each do |port|
      abort "Unexpected protocol/port" unless port.fetch("protocol") == "tcp" && port.fetch("published").to_i == port.fetch("target")
      sockets << TCPServer.new(port.fetch("host_ip", "0.0.0.0"), port.fetch("published").to_i)
    end
    actual = ports.map { |port| [port.fetch("host_ip"), port.fetch("target")] }.sort
    abort "Wrong published interfaces: #{actual.inspect}" unless actual == [["127.0.0.1", 443], ["203.0.113.9", 80], ["203.0.113.9", 443]]
    [["100.98.160.115", 443], ["fd7a:115c:a1e0::6634:a074", 443], ["203.0.113.9", 80], ["203.0.113.9", 443], ["127.0.0.1", 443]].each do |address, port|
      TCPSocket.new(address, port).close
    end
    output, status = Open3.capture2e("bash", "-euo", "pipefail", "-c", check)
    abort "Occupied endpoints passed preflight" if status.success?
    abort output unless output.include?("Ingress endpoint in use")
    puts "PASS: exact public + loopback ports coexist; both tailnet listeners remain reachable; real preflight refuses occupied endpoints"
  ensure
    sockets.reverse_each(&:close)
  end
RUBY
script = <<~SH
  ip link set lo up
  ip link add public0 type dummy
  ip link set public0 up
  ip addr add 203.0.113.9/32 dev public0
  ip addr add 100.98.160.115/32 dev lo
  ip -6 addr add fd7a:115c:a1e0::6634:a074/128 dev lo nodad
  ip route add default dev public0 src 203.0.113.9
  exec "$2" -rjson -rsocket -ropen3 -rshellwords -e #{Shellwords.escape(kernel)} "$1" "$3"
SH
command = [ "unshare", "--net", "bash", "-ec", script, "bash", JSON.generate(ports), RbConfig.ruby, File.join(root, "ops/vps/cli.sh") ]
command.unshift("sudo", "-n") unless Process.uid.zero?
output, status = Open3.capture2e(*command)
puts output
abort "Ingress kernel proof failed" unless status.success?
puts "CLEAN: disposable network namespace exited; no Docker daemon, host listener, firewall or sysctl changed"
