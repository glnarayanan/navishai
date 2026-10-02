#!/usr/bin/env ruby
# Disposable orb-only integration proof. Never use a shared daemon or live VPS.
require "digest"
require "etc"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "shellwords"
require "tmpdir"

abort "Usage: ruby test/support/vps_policy_proof.rb" unless ARGV.empty?
File.umask(0o022)
$stdout.sync = true
root = File.expand_path("../..", __dir__)
directory = Dir.mktmpdir("vp-")
File.chmod(0o700, directory)
prefix = "vp-#{SecureRandom.hex(4)}"
project = "navishai-reset"
services = []
cleanup_errors = []
environment = { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"), "USER" => Etc.getpwuid.name,
  "LOGNAME" => Etc.getpwuid.name, "DOCKER_BUILDKIT" => "0" }
capture = lambda do |*command, input: ""|
  Open3.capture2e(environment, *command, stdin_data: input, unsetenv_others: true)
end
run = lambda do |*command, input: ""|
  output, status = capture.call(*command, input:)
  raise "#{command.first} failed:\n#{output}" unless status.success?
  output
end
start = lambda do |suffix, command|
  name = "#{prefix}-#{suffix}"
  services << name unless services.include?(name)
  run.call("amp", "orb", "service", "start", name, "--command", Shellwords.join(command))
end
wait = lambda do |label, &probe|
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
  loop do
    begin
      break if probe.call
    rescue RuntimeError
      nil
    end
    raise "Timed out: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.5
  end
end
snapshot = lambda do
  %w[iptables-save ip6tables-save].map { |tool| run.call("sudo", "-n", tool).lines.reject { |line| line.start_with?("#") }.join } +
    %w[net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables].map { |key| run.call("sudo", "-n", "sysctl", "-n", key) }
end
host = snapshot.call
compose = nil
docker = nil
begin
  base = "6c9fa890127c7cbfac59b810f68ebd9b3bb77603"
  archive = File.join(directory, "source.tar")
  source = File.join(directory, "source")
  Dir.mkdir(source)
  run.call("git", "-C", root, "archive", "--output=#{archive}", base)
  run.call("tar", "-xf", archive, "-C", source)
  puts "BUILD: exact base #{base}; private project #{project}, service prefix #{prefix}."
  cli = File.join(directory, "compose")
  url = "https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-x86_64"
  run.call("curl", "--fail", "--location", "--silent", "--show-error", url, "--output", cli)
  checksum = run.call("curl", "--fail", "--location", "--silent", "--show-error", "#{url}.sha256").split.first
  raise "Compose checksum" unless checksum.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(cli).hexdigest == checksum
  File.chmod(0o700, cli)
  daemon = lambda do |suffix, isolated|
    home = File.join(directory, suffix)
    Dir.mkdir(home)
    File.write(File.join(home, "daemon.json"), "{}")
    socket = "unix://#{home}/docker.sock"
    command = [ "sudo", "-n" ]
    command += [ "nsenter", "--net=#{directory}/netns" ] if isolated
    command += [ "dockerd", "--config-file=#{home}/daemon.json", "--host=#{socket}", "--data-root=#{home}/data", "--exec-root=#{home}/exec",
      "--pidfile=#{home}/pid", "--storage-driver=vfs", "--bridge=none", "--userland-proxy=#{isolated}",
      "--iptables=#{isolated}", "--ip6tables=#{isolated}", "--ip-masq=#{isolated}", "--ip-forward=#{isolated}" ]
    client = [ "sudo", "-n", "docker", "--config", home, "--host", socket ]
    start.call(suffix, command)
    wait.call("#{suffix} daemon") { run.call(*client, "info", "--format", "{{.DockerRootDir}}").strip == "#{home}/data" }
    [ client, command ]
  end
  builder, = daemon.call("build", false)
  postgres_pin = "postgres:16@sha256:1a6ab3f5345eb6dbe04a1349529caabdb0ab09293a09590fad07b2246bfa4b54"
  run.call(*builder, "pull", postgres_pin)
  postgres_id = run.call(*builder, "image", "inspect", "--format", "{{.Id}}", postgres_pin).strip
  run.call(*builder, "tag", postgres_pin, "#{prefix}-postgres:local")
  puts run.call(*builder, "build", "--network=host", "--memory=1g", "--cpu-period=100000", "--cpu-quota=200000", "--tag", "#{prefix}:local", source)
  images = File.join(directory, "images.tar")
  run.call(*builder, "save", "--output", images, "#{prefix}:local", "#{prefix}-postgres:local")
  File.write(File.join(directory, "netns"), "")
  start.call("net", [ "sudo", "-n", "unshare", "--net", "sh", "-ec",
    "mount --bind /proc/self/ns/net #{Shellwords.escape(directory)}/netns; ip link set lo up; exec sleep infinity" ])
  namespace = [ "sudo", "-n", "nsenter", "--net=#{directory}/netns" ]
  wait.call("namespace") { run.call(*namespace, "ip", "link", "show", "lo").include?("UP") }
  docker, daemon_command = daemon.call("run", true)
  run.call(*docker, "load", "--input", images)
  raise "Pinned PostgreSQL identity changed" unless postgres_id == run.call(*docker, "image", "inspect", "--format", "{{.Id}}", "#{prefix}-postgres:local").strip
  composition = File.join(directory, "compose.yaml")
  File.write(composition, <<~YAML)
    services:
      app-net:
        image: #{prefix}:local
        entrypoint: [sleep, infinity]
        user: "1000:1000"
        cap_drop: [ALL]
        security_opt: [no-new-privileges:true]
        restart: "no"
        labels: {com.navishai.owner: navishai-reset}
        ports: ["127.0.0.1:3000:3000"]
        networks: [control, edge]
      postgres:
        image: #{prefix}-postgres:local
        environment: {POSTGRES_PASSWORD: "#{SecureRandom.hex(32)}"}
        restart: "no"
        labels: {com.navishai.owner: navishai-reset}
        networks: [control]
      web:
        image: #{prefix}:local
        entrypoint: [sleep, infinity]
        user: "1000:1000"
        cap_drop: [ALL]
        security_opt: [no-new-privileges:true]
        restart: "no"
        network_mode: service:app-net
      jobs:
        extends: {service: web}
    networks:
      control:
        internal: true
        labels: {com.navishai.owner: navishai-reset}
      edge:
        labels: {com.navishai.owner: navishai-reset}
  YAML
  File.chmod(0o600, composition)
  compose = [ "sudo", "-n", cli, "--host", docker.last, "--project-name", project, "--file", composition ]
  wrapper = File.join(directory, "policy-client.sh")
  File.write(wrapper, <<~SH, perm: 0o700)
    set -euo pipefail
    VPS_PROJECT=navishai-reset
    vps_compose() { #{Shellwords.join(compose.drop(2))} "$@"; }
    vps_docker() { #{Shellwords.join(docker.drop(2))} "$@"; }
    source #{Shellwords.escape(File.join(root, "ops/vps/policy.sh"))}
    if [[ $1 == unavailable-ipv6 ]]; then
      nsenter() { [[ $2 != ip6tables ]] || return 1; command nsenter "$@"; }
      vps_policy_apply
      exit "$?"
    fi
    "vps_policy_$1"
  SH
  policy = lambda do |action, allowed = true|
    output, status = capture.call("sudo", "-n", "bash", wrapper, action)
    raise "Policy #{action}: unexpected result:\n#{output}" unless status.success? == allowed
    puts output.strip
  end
  run.call(*compose, "up", "--detach", "--no-build", "app-net", "postgres")
  holder = run.call(*compose, "ps", "--quiet", "app-net").strip
  pg = run.call(*compose, "ps", "--quiet", "postgres").strip
  wait.call("postgres") { run.call(*docker, "exec", pg, "pg_isready", "-U", "postgres").include?("accepting") }
  holder_info = JSON.parse(run.call(*docker, "inspect", holder)).first
  holder_ns = [ "sudo", "-n", "nsenter", "--net=/proc/#{holder_info.fetch('State').fetch('Pid')}/ns/net" ]
  holder_ip = holder_info.fetch("NetworkSettings").fetch("Networks").fetch("#{project}_control").fetch("IPAddress")
  pg_info = JSON.parse(run.call(*docker, "inspect", pg)).first
  pg_ip = pg_info.fetch("NetworkSettings").fetch("Networks").fetch("#{project}_control").fetch("IPAddress")
  pg_ns = [ "sudo", "-n", "nsenter", "--net=/proc/#{pg_info.fetch('State').fetch('Pid')}/ns/net" ]
  addresses4 = %w[93.184.216.34 169.254.169.254 100.64.1.2 198.18.0.1 192.168.30.1]
  addresses6 = %w[2001:4860:feed::1 fd00:feed::1 2001:db8::1 2002::1 3fff::1]
  addresses4.each { |ip| run.call(*namespace, "ip", "addr", "add", "#{ip}/32", "dev", "lo") }
  edge_id = run.call(*docker, "network", "inspect", "--format", "{{.Id}}", "#{project}_edge").strip
  bridge = "br-#{edge_id[0, 12]}"
  # IPv6 changes occur only in these disposable namespaces, never on the host.
  run.call(*namespace, "sysctl", "-w", "net.ipv6.conf.#{bridge}.disable_ipv6=0")
  run.call(*namespace, "ip", "-6", "addr", "add", "#{addresses6.first}/64", "dev", bridge, "nodad")
  addresses6.drop(1).each { |ip| run.call(*namespace, "ip", "-6", "addr", "add", "#{ip}/128", "dev", "lo", "nodad") }
  configure_ipv6 = lambda do |info, client_namespace|
    edge_ip = info.fetch("NetworkSettings").fetch("Networks").fetch("#{project}_edge").fetch("IPAddress")
    interface = JSON.parse(run.call(*client_namespace, "ip", "-j", "addr")).find { |link| link.fetch("addr_info").any? { |address| address["local"] == edge_ip } }.fetch("ifname")
    run.call(*client_namespace, "sysctl", "-w", "net.ipv6.conf.#{interface}.disable_ipv6=0")
    run.call(*client_namespace, "sysctl", "-w", "net.ipv6.conf.lo.disable_ipv6=0")
    run.call(*client_namespace, "ip", "-6", "addr", "add", "2001:4860:feed::2/64", "dev", interface, "nodad")
    run.call(*client_namespace, "ip", "-6", "route", "add", "default", "via", addresses6.first, "dev", interface)
  end
  configure_ipv6.call(holder_info, holder_ns)
  peer = File.join(root, "test/support/vps_policy_peer.rb")
  record = File.join(directory, "messages")
  start.call("peer", namespace + [ RbConfig.ruby, peer, "9443", record ])
  start.call("pg-port", pg_ns + [ RbConfig.ruby, peer, "8443" ])
  run.call(*docker, "cp", peer, "#{holder}:/rails/tmp/vps-policy-peer.rb")
  start.call("ingress", docker + [ "exec", holder, "ruby", "/rails/tmp/vps-policy-peer.rb", "3000" ])
  probe = lambda do |container, address, allowed, port = "9443"|
    run.call(*docker, "exec", container, "ruby", "-rsocket", "-rtimeout", "-e", <<~'RUBY', address, port, allowed.to_s)
      address, port, allowed = ARGV
      begin
        Timeout.timeout(3) { TCPSocket.open(address, Integer(port)) { |socket| socket.puts("probe"); raise "Wrong echo" unless socket.gets == "probe\n" } }
        abort "Forbidden destination connected: #{address}" unless allowed == "true"
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH
        abort "Allowed destination denied: #{address}" unless allowed == "false"
      end
    RUBY
  end
  wait.call("echo") { probe.call(holder, addresses4.first, true); true }
  [ *addresses4, *addresses6 ].each { |ip| probe.call(holder, ip, true) }
  wait.call("ingress") { probe.call(holder, "127.0.0.1", true, "3000"); true }
  wait.call("postgres alternate port") { probe.call(holder, pg_ip, true, "8443"); true }
  probe.call(holder, holder_ip, true, "3000")
  probe.call(holder, "::1", true, "3000")
  unrelated = %w[iptables ip6tables].map do |family|
    run.call(*holder_ns, family, "-N", "VPS_PROOF_UNRELATED")
    run.call(*holder_ns, family, "-A", "VPS_PROOF_UNRELATED", "-j", "RETURN")
    [ run.call(*holder_ns, family, "-S", "VPS_PROOF_UNRELATED"),
      run.call(*holder_ns, "#{family}-save", "-t", "nat").lines.reject { |line| line.start_with?("#") }.join ]
  end
  policy.call("unavailable-ipv6", false)
  raise "IPv4 written despite unavailable IPv6" if run.call(*holder_ns, "iptables", "-S").include?("NAVISHAI_OUTPUT")
  puts "PASS: all simulated IPv4/IPv6 public/private/special destinations reachable BEFORE policy."
  # Hold a forbidden ORIGINAL-direction connection open across installation.
  start.call("held", docker + [ "exec", holder, "ruby", "-rsocket", "-rtimeout", "-e", <<~'RUBY', addresses4[1] ])
    socket = TCPSocket.new(ARGV[0], 9443)
    socket.puts("before")
    raise "Before echo" unless socket.gets == "before\n"
    File.write("/rails/tmp/vps-policy-ready", "ready")
    sleep 0.1 until File.exist?("/rails/tmp/vps-policy-send")
    begin
      Timeout.timeout(4) { socket.puts("after"); raise "Forbidden established data delivered" if socket.gets == "after\n" }
    rescue SystemCallError, Timeout::Error
      nil
    end
    File.write("/rails/tmp/vps-policy-done", "denied")
  RUBY
  wait.call("held connection") { run.call(*docker, "exec", holder, "test", "-f", "/rails/tmp/vps-policy-ready"); true }
  policy.call("check", false)
  policy.call("apply")
  policy.call("apply")
  policy.call("check")
  %w[iptables ip6tables].each_with_index do |family, index|
    actual = [ run.call(*holder_ns, family, "-S", "VPS_PROOF_UNRELATED"),
      run.call(*holder_ns, "#{family}-save", "-t", "nat").lines.reject { |line| line.start_with?("#") }.join ]
    raise "Unrelated chain/NAT changed" unless unrelated[index] == actual
  end
  puts "PASS: unavailable IPv6 refuses before writing IPv4; unrelated chains and Docker DNS NAT unchanged."
  run.call(*docker, "exec", holder, "touch", "/rails/tmp/vps-policy-send")
  wait.call("established original denied") { run.call(*docker, "exec", holder, "test", "-f", "/rails/tmp/vps-policy-done"); true }
  raise "Forbidden connection kept sending" if run.call("sudo", "-n", "cat", record).lines.include?("after\n")
  puts "PASS: pre-policy forbidden established ORIGINAL connection cannot keep sending."
  run.call(*compose, "up", "--detach", "--no-build", "web", "jobs")
  workloads = %w[web jobs].map { |name| run.call(*compose, "ps", "--quiet", name).strip }
  verify = lambda do
    [ holder, *workloads ].each do |container|
      probe.call(container, addresses4.first, true)
      addresses4.drop(1).each { |ip| probe.call(container, ip, false) }
      # Only the real PostgreSQL TCP5432 destination, not any control address/port.
      run.call(*docker, "exec", container, "pg_isready", "-h", pg_ip, "-U", "postgres")
      probe.call(container, pg_ip, false, "8443")
      probe.call(container, holder_ip, false, "3000")
      probe.call(container, "127.0.0.1", true, "3000")
      probe.call(container, "::1", true, "3000")
      run.call(*docker, "exec", container, "ruby", "-rresolv", "-rsocket", "-rtimeout", "-e", <<~'RUBY', pg_ip)
        Timeout.timeout(4) do
          dns = Resolv::DNS.new(nameserver_port: [["127.0.0.11", 53]])
          abort "UDP DNS" unless dns.getaddress("postgres").to_s == ARGV[0]
          packet = [1234, 0x100, 1, 0, 0, 0].pack("n6") + "\x08postgres\x00" + [1, 1].pack("n2")
          TCPSocket.open("127.0.0.11", 53) do |socket|
            socket.write([packet.bytesize].pack("n") + packet)
            response = socket.read(socket.read(2).unpack1("n"))
            decoded = Resolv::DNS::Message.decode(response)
            abort "TCP DNS" unless decoded.id == 1234 && decoded.qr == 1 && decoded.rcode.zero? &&
              decoded.answer.any? { |_, _, resource| resource.is_a?(Resolv::DNS::Resource::IN::A) && resource.address.to_s == ARGV[0] }
          end
        end
      RUBY
    end
    probe.call(holder, addresses6.first, true)
    addresses6.drop(1).each { |ip| probe.call(holder, ip, false) }
    run.call(*docker, "exec", pg, "bash", "-ec", "exec 3<>/dev/tcp/#{holder_ip}/3000; printf 'reply\\n' >&3; read -r response <&3; test \"$response\" = reply")
    %w[iptables ip6tables].each do |family|
      counters = run.call(*holder_ns, family, "-L", "NAVISHAI_OUTPUT", "-v", "-n", "-x")
      raise "No kernel #{family} rejection" unless counters.lines.any? { |line| line.include?("REJECT") && line.split.first.to_i.positive? }
    end
    puts "PASS: kernel IPv4/IPv6 REJECT counters; public/loopback/UDP+TCP Docker DNS/only PostgreSQL5432 and inbound replies preserved."
  end
  verify.call
  %w[iptables ip6tables].each do |family|
    run.call(*holder_ns, family, "-I", "OUTPUT", "1", "-j", "ACCEPT")
    policy.call("check", false)
    policy.call("apply", false)
    run.call(*holder_ns, family, "-D", "OUTPUT", "1")
    run.call(*holder_ns, family, "-I", "NAVISHAI_OUTPUT", "1", "-j", "ACCEPT")
    policy.call("check", false)
    policy.call("apply", false)
    run.call(*holder_ns, family, "-D", "NAVISHAI_OUTPUT", "1")
  end
  policy.call("check")
  run.call(*compose, "restart", "web", "jobs")
  policy.call("check")
  verify.call
  puts "PASS: both families reject shadowed OUTPUT and altered chains; web/jobs restart preserves policy."
  run.call(*compose, "stop")
  %w[ingress held pg-port].each do |suffix|
    name = "#{prefix}-#{suffix}"
    run.call("amp", "orb", "service", "stop", name)
    services.delete(name)
  end
  run.call("amp", "orb", "service", "stop", "#{prefix}-run")
  start.call("run", daemon_command)
  wait.call("daemon restart") { run.call(*docker, "info"); true }
  raise "Docker auto-start window" unless run.call(*docker, "ps", "--quiet").strip.empty?
  policy.call("check", false)
  run.call(*compose, "up", "--detach", "--no-build", "--force-recreate", "app-net", "postgres")
  holder = run.call(*compose, "ps", "--quiet", "app-net").strip
  holder_info = JSON.parse(run.call(*docker, "inspect", holder)).first
  holder_ns = [ "sudo", "-n", "nsenter", "--net=/proc/#{holder_info.fetch('State').fetch('Pid')}/ns/net" ]
  configure_ipv6.call(holder_info, holder_ns)
  [ *addresses4, *addresses6 ].each { |ip| probe.call(holder, ip, true) }
  policy.call("check", false)
  policy.call("apply")
  policy.call("check")
  [ *addresses4.drop(1), *addresses6.drop(1) ].each { |ip| probe.call(holder, ip, false) }
  [ addresses4.first, addresses6.first ].each { |ip| probe.call(holder, ip, true) }
  puts "PASS: daemon restart leaves workloads stopped; holder/PostgreSQL replacement requires explicit reapply before startup."
ensure
  clean = lambda do |*command|
    run.call(*command)
  rescue StandardError => error
    cleanup_errors << error.message
    nil
  end
  clean.call(*compose, "down", "--volumes", "--remove-orphans", "--rmi", "local") if compose
  services.reverse_each { |name| clean.call("amp", "orb", "service", "stop", name) }
  clean.call("findmnt", "--raw", "--noheadings", "--output", "TARGET").to_s.lines.map(&:strip)
    .select { |path| path.start_with?("#{directory}/") }.sort_by(&:length).reverse_each { |path| clean.call("sudo", "-n", "umount", path) }
  clean.call("sudo", "-n", "rm", "-rf", "--", directory) if cleanup_errors.empty?
  raise "Cleanup failed in #{directory}: #{cleanup_errors.join('; ')}" unless cleanup_errors.empty?
  raise "Host firewall/sysctl changed" unless host == snapshot.call
  puts "CLEAN: exact private daemons/Compose project/namespaces/images/volumes/files removed; host IPv4/IPv6 rules/sysctls unchanged."
end
puts "LIMIT: disposable orb proof, not systemd reboot/public HTTPS/VPS/provider/live-data acceptance."
