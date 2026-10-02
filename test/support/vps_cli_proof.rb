#!/usr/bin/env ruby
# Disposable orb-only CLI proof. Never select a shared daemon or a live VPS.
require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "shellwords"
require "tmpdir"

abort "Usage: ruby test/support/vps_cli_proof.rb" unless ARGV.empty?
File.umask(0o022)
$stdout.sync = true
root = File.expand_path("../..", __dir__)
base = "6c9fa890127c7cbfac59b810f68ebd9b3bb77603"
required_files = %w[bin/navishai-vps ops/vps/cli.sh ops/vps/compose.yaml ops/vps/Caddyfile ops/vps/initialize_roles.sh ops/vps/policy.sh ops/vps/recovery.sh]
required_files.each { |path| abort "Missing transferred production source: #{path}" unless File.file?(File.join(root, path)) }
production_files = [ "bin/navishai-vps", *Dir.glob("ops/vps/*", base: root).select { |path| File.file?(File.join(root, path)) }.sort ]
directory = Dir.mktmpdir("vc-")
File.chmod(0o700, directory)
prefix = "vc-#{SecureRandom.hex(4)}"
services = []
cleanup_errors = []
secrets = []
environment = { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"), "USER" => Etc.getpwuid.name,
  "LOGNAME" => Etc.getpwuid.name, "DOCKER_BUILDKIT" => "0", "COMPOSE_BAKE" => "false" }
redact = ->(output) { secrets.reduce(output) { |text, secret| text.gsub(secret, "<REDACTED>") } }
capture = lambda do |*command, input: ""|
  output, status = Open3.capture2e(environment, *command, stdin_data: input, unsetenv_others: true)
  [ redact.call(output), status ]
end
run = lambda do |*command, input: ""|
  output, status = capture.call(*command, input:)
  raise "#{command.first} failed:\n#{output}" unless status.success?
  output
end
start_service = lambda do |suffix, command|
  name = "#{prefix}-#{suffix}"
  services << name unless services.include?(name)
  run.call("amp", "orb", "service", "start", name, "--command", Shellwords.join(command))
end
stop_service = lambda do |suffix|
  name = "#{prefix}-#{suffix}"
  run.call("amp", "orb", "service", "stop", name)
  services.delete(name)
end
wait = lambda do |label, &probe|
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
  last = nil
  loop do
    begin
      break if probe.call
    rescue RuntimeError => error
      last = error.message
    end
    raise "Timed out: #{label}: #{last}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 1
  end
end
host_snapshot = lambda do
  %w[iptables-save ip6tables-save].map { |tool| run.call("sudo", "-n", tool).lines.reject { |line| line.start_with?("#") }.join } +
    %w[net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables].map { |key| run.call("sudo", "-n", "sysctl", "-n", key) }
end
host = host_snapshot.call
docker = nil
begin
  raise "Exact base unavailable" unless run.call("git", "-C", root, "rev-parse", "#{base}^{commit}").strip == base
  source = File.join(directory, "source")
  run.call("git", "clone", "--quiet", "--shared", root, source)
  run.call("git", "-C", source, "checkout", "--quiet", "--detach", base)
  production_files.each do |path|
    FileUtils.mkdir_p(File.dirname(File.join(source, path)))
    FileUtils.cp(File.join(root, path), File.join(source, path))
  end
  # Thread file transfer carries bytes, not executable mode. The real entrypoint needs it.
  File.chmod(0o755, File.join(source, "bin/navishai-vps"))
  caddyfile = File.join(source, "ops/vps/Caddyfile")
  text = File.read(caddyfile)
  raise "Unexpected Caddy source" unless text.scan("reverse_proxy app-net:3000").length == 1
  File.write(caddyfile, text.sub("reverse_proxy app-net:3000", "tls internal\n  reverse_proxy app-net:3000"))
  commit_source = lambda do |message|
    run.call("git", "-C", source, "add", "--all")
    run.call("git", "-C", source, "-c", "user.name=Disposable proof", "-c", "user.email=proof@example.invalid", "commit", "--quiet", "-m", message)
    run.call("git", "-C", source, "rev-parse", "HEAD").strip
  end
  release1 = commit_source.call("test: synthetic production source with internal TLS")
  source_manifest = production_files.to_h { |path| [ path, Digest::SHA256.file(File.join(root, path)).hexdigest ] }
  puts "SOURCE: exact base #{base}; synthetic release #{release1}; production file SHA256 #{JSON.generate(source_manifest)}"
  compose_binary = File.join(directory, "compose")
  url = "https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-x86_64"
  run.call("curl", "--fail", "--location", "--silent", "--show-error", url, "--output", compose_binary)
  checksum = run.call("curl", "--fail", "--location", "--silent", "--show-error", "#{url}.sha256").split.first
  raise "Compose checksum" unless checksum.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(compose_binary).hexdigest == checksum
  File.chmod(0o755, compose_binary)
  daemon = lambda do |suffix, isolated|
    home = File.join(directory, suffix)
    FileUtils.mkdir_p(home)
    File.write(File.join(home, "daemon.json"), "{}")
    FileUtils.mkdir_p(File.join(home, "cli-plugins"))
    FileUtils.cp(compose_binary, File.join(home, "cli-plugins/docker-compose"))
    socket = "unix://#{home}/docker.sock"
    command = [ "sudo", "-n" ]
    command += [ "nsenter", "--net=#{directory}/netns" ] if isolated
    command += [ "dockerd", "--config-file=#{home}/daemon.json", "--host=#{socket}", "--data-root=#{home}/data", "--exec-root=#{home}/exec",
      "--pidfile=#{home}/pid", "--storage-driver=vfs", "--bridge=none", "--userland-proxy=#{isolated}",
      "--iptables=#{isolated}", "--ip6tables=#{isolated}", "--ip-masq=#{isolated}", "--ip-forward=#{isolated}" ]
    client = [ "sudo", "-n", "docker", "--config", home, "--host", socket ]
    start_service.call(suffix, command)
    wait.call("#{suffix} daemon") { run.call(*client, "info", "--format", "{{.DockerRootDir}}").strip == "#{home}/data" }
    [ client, command ]
  end
  builder, = daemon.call("build", false)
  pins = %w[postgres:16@sha256:1a6ab3f5345eb6dbe04a1349529caabdb0ab09293a09590fad07b2246bfa4b54 caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d]
  pins.each { |pin| puts run.call(*builder, "pull", pin) }
  # Match the CLI archive, including SOURCE_COMMIT, to keep the actual offline build cached.
  build_source = File.join(directory, "build-source")
  Dir.mkdir(build_source)
  archive = File.join(directory, "source.tar")
  run.call("git", "-C", source, "archive", "--output=#{archive}", release1)
  # Root tar preserves archive modes (0664); unprivileged tar strips group write.
  # Classic COPY cache keys distinguish those modes even with identical bytes.
  run.call("sudo", "-n", "tar", "-xf", archive, "-C", build_source)
  File.write(File.join(build_source, "SOURCE_COMMIT"), "#{release1}\n")
  # Match the CLI's root ownership and readable, non-group-writable release.
  run.call("sudo", "-n", "chown", "-R", "root:root", build_source)
  run.call("sudo", "-n", "chmod", "-R", "a+rX,go-w", build_source)
  # Use the same tar producer as the real installer, not standalone Docker CLI.
  # Only the warm builder needs downloads; no runtime Compose override changes.
  warm_network = File.join(directory, "warm-network.yaml")
  File.write(warm_network, "services:\n  web:\n    build:\n      network: host\n")
  warm_env = File.join(directory, "warm.env")
  password = SecureRandom.hex(32)
  secrets << password
  File.write(warm_env, <<~ENV, perm: 0o600)
    VPS_IMAGE=navishai-reset:#{release1}
    NAVISHAI_APP_HOST=proof.example.invalid
    NAVISHAI_ACME_EMAIL=proof@example.invalid
    NAVISHAI_DATABASE_PASSWORD=#{password}
    NAVISHAI_POSTGRES_PASSWORD=#{password}
    NAVISHAI_PREPARE_PASSWORD=#{password}
    NAVISHAI_SECRET_KEY_BASE=#{password}
  ENV
  warm_output = run.call("sudo", "-n", "env", "DOCKER_BUILDKIT=0", "COMPOSE_BAKE=false", *builder.drop(2), "compose", "--project-name", "navishai-reset", "--project-directory", build_source,
    "--env-file", warm_env, "--file", File.join(build_source, "compose.yaml"), "--file", File.join(build_source, "ops/vps/compose.yaml"),
    "--file", warm_network, "build", "web")
  raise "Warm Compose builder did not use the classic path" unless warm_output.match?(/Step \d+\/\d+ : COPY Gemfile Gemfile.lock/)
  puts warm_output
  stop_service.call("build")
  # Save/load loses RepoDigest and intermediate build cache. Copy only a stopped private daemon.
  FileUtils.mkdir_p(File.join(directory, "run"))
  run.call("sudo", "-n", "cp", "-a", "#{directory}/build/data", "#{directory}/run/data")
  File.write(File.join(directory, "netns"), "")
  start_service.call("net", [ "sudo", "-n", "unshare", "--net", "sh", "-ec",
    "mount --bind /proc/self/ns/net #{Shellwords.escape(directory)}/netns; ip link set lo up; exec sleep infinity" ])
  namespace = [ "sudo", "-n", "nsenter", "--net=#{directory}/netns" ]
  wait.call("namespace") { run.call(*namespace, "ip", "link", "show", "lo").include?("UP") }
  docker, daemon_command = daemon.call("run", true)
  pins.each { |pin| run.call(*docker, "image", "inspect", pin) }
  managed = File.join(directory, "host")
  wrappers = File.join(directory, "bin")
  FileUtils.mkdir_p([ managed, wrappers ])
  systemctl_log = File.join(directory, "systemctl.log")
  docker_audit = File.join(directory, "docker-audit.jsonl")
  staged_audit = File.join(directory, "staged-audit.jsonl")
  tar_audit = File.join(directory, "tar-audit.log")
  ca = File.join(directory, "caddy-root.crt")
  File.write(File.join(wrappers, "docker"), <<~SH, perm: 0o755)
    #!/usr/bin/env bash
    set -euo pipefail
    real() { /usr/bin/docker --config #{directory}/run --host #{docker.last} "$@"; }
    state() {
      local id
      id=$(real ps -aq --no-trunc --filter label=com.docker.compose.project=navishai-reset --filter label=com.docker.compose.service="$1" --filter label=com.docker.compose.oneoff=False)
      [[ $id =~ ^[0-9a-f]{64}$ ]] || { echo 'PROOF: missing/duplicate staged service' >&2; exit 97; }
      real inspect --format '{"id":{{json .Id}},"running":{{json .State.Running}}}' "$id"
    }
    controls() { state app-net; state postgres; }
    stable_controls() {
      local current
      current=$(controls)
      [[ $current == "$(cat #{directory}/staged-controls)" ]] || { echo 'PROOF: staging replaced holder/PostgreSQL or changed Running state' >&2; exit 97; }
      jq -e -s 'length == 2 and all(.[]; .running == true)' <<< "$current" >/dev/null
    }
    staged() {
      stable_controls
      local service
      for service in web jobs; do
        state "$service" | jq -e '.running == false' >/dev/null || { echo 'PROOF: runtime started before pre-start inspection' >&2; exit 97; }
      done
    }
    # Observe real pre-start inspections without changing Docker responses.
    if [[ $1 == inspect && -f #{directory}/staged-controls && ${@: -1} =~ ^[0-9a-f]{64}$ ]]; then
      service=$(real inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${@: -1}")
      if [[ $service == web || $service == jobs ]]; then
        staged
        printf '{"service":"%s","timeNano":%s}\\n' "$service" "$(date +%s%N)" >> #{staged_audit}
      fi
    fi
    if [[ $1 == compose && " $* " == *' start '* && -f #{directory}/staged-controls ]]; then
      staged
      rm -- #{directory}/staged-controls
    fi
    staging=false
    if [[ $1 == compose && " $* " == *' up '* && " $* " == *' --no-start '* ]]; then staging=true; fi
    maintenance=$staging
    if [[ $1 == run ]] || [[ $1 == exec && " $* " =~ (pg_dump|pg_restore|psql|tar) ]] ||
       [[ $1 == compose && " $* " == *' exec '* && " $* " =~ (pg_dump|pg_restore|psql|tar) ]] ||
       [[ $1 == compose && " $* " == *' run '* ]] || [[ $1 == image && ${2:-} == save ]]; then maintenance=true; fi
    stopped() {
      local service ids
      for service in web jobs proxy; do
        ids=$(real ps -q --filter label=com.docker.compose.project=navishai-reset --filter label=com.docker.compose.service="$service" --filter label=com.docker.compose.oneoff=False)
        [[ -z $ids ]] || { echo 'PROOF: writer active during maintenance' >&2; exit 97; }
      done
    }
    if ! $maintenance; then exec /usr/bin/docker --config #{directory}/run --host #{docker.last} "$@"; fi
    stopped
    if $staging; then controls > #{directory}/staged-controls; stable_controls; fi
    printf '{"phase":"before","timeNano":%s}\\n' "$(date +%s%N)" >> #{docker_audit}
    result=0
    real "$@" || result=$?
    stopped
    if $staging && ((result == 0)); then staged; fi
    printf '{"phase":"after","timeNano":%s,"tool":"%s","status":%s}\\n' "$(date +%s%N)" "$1" "$result" >> #{docker_audit}
    exit "$result"
  SH
  # Forward real tar bytes; retain only archive headers for failed-guard diagnosis.
  File.write(File.join(wrappers, "tar"), <<~SH, perm: 0o755)
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ " $* " != *' --list '* ]]; then exec /usr/bin/tar "$@"; fi
    archive=${@: -1}
    printf 'BEGIN %s\\n' "${archive##*/}" >> #{tar_audit}
    set +e
    /usr/bin/tar "$@" | tee -a #{tar_audit}
    results=("${PIPESTATUS[@]}")
    set -e
    ((results[1] == 0)) || { echo 'PROOF: archive-header audit failed' >&2; exit 97; }
    printf 'END status=%s\\n' "${results[0]}" >> #{tar_audit}
    exit "${results[0]}"
  SH
  File.write(File.join(wrappers, "curl"), <<~SH, perm: 0o755)
    #!/usr/bin/env bash
    set -euo pipefail
    extra=()
    for arg in "$@"; do
      if [[ $arg == https://proof.example.invalid/* ]]; then
        # The production HTTPS gate runs inside install, before the Ruby caller returns.
        if [[ ! -s #{ca} ]]; then
          proxy=$(docker ps -q --no-trunc --filter label=com.docker.compose.project=navishai-reset --filter label=com.docker.compose.service=proxy)
          [[ $proxy =~ ^[0-9a-f]{64}$ ]] || exit 1
          docker cp "$proxy:/data/caddy/pki/authorities/local/root.crt" #{ca}.new >/dev/null 2>&1
          mv #{ca}.new #{ca}
        fi
        extra=(--cacert #{ca})
      fi
    done
    exec nsenter --net=#{directory}/netns /usr/bin/curl "${extra[@]}" "$@"
  SH
  # Run the exact generated startup child; do not fake systemctl-start success or locks.
  File.write(File.join(wrappers, "systemctl"), <<~SH, perm: 0o755)
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\\n' "$*" >> #{systemctl_log}
    if [[ $1 == start && " $* " == *' navishai-reset.service '* ]]; then
      line=$(sed -n 's/^ExecStart=//p' #{managed}/etc/systemd/system/navishai-reset.service)
      read -r -a command <<< "$line"
      result=0
      timeout 420 "${command[@]}" || result=$?
      if ((result != 0)); then
        line=$(sed -n 's/^ExecStopPost=//p' #{managed}/etc/systemd/system/navishai-reset.service)
        read -r -a command <<< "$line"
        "${command[@]}"
      fi
      exit "$result"
    elif [[ $1 == disable && " $* " == *' --now '* ]]; then
      line=$(sed -n 's/^ExecStop=//p' #{managed}/etc/systemd/system/navishai-reset.service)
      read -r -a command <<< "$line"
      "${command[@]}"
    fi
  SH
  run.call("sudo", "-n", "chown", "-R", "root:root", managed, wrappers, source)
  run.call("sudo", "-n", "chown", "root:root", directory)
  run.call("sudo", "-n", "chmod", "755", directory)
  run.call("sudo", "-n", "chmod", "700", managed)
  private_env = File.join(directory, "proof.env")
  cli_prefix = [ "sudo", "-n", "env", "PATH=#{wrappers}:/usr/local/sbin:/usr/sbin:/sbin:#{environment.fetch('PATH')}", "DOCKER_BUILDKIT=0", "COMPOSE_BAKE=false", "timeout", "900", File.join(source, "bin/navishai-vps"), "--root", managed ]
  cli = lambda do |*arguments, allowed: true|
    output, status = capture.call(*cli_prefix, *arguments)
    unless status.success? == allowed
      diagnostics = "exit=#{status.exitstatus.inspect}, signal=#{status.termsig.inspect}"
      if arguments.first == "backup"
        diagnostics += "; published=#{File.directory?(arguments.last)}"
        [ docker_audit, tar_audit ].each do |path|
          next unless File.file?(path)
          lines = run.call("sudo", "-n", "cat", path).lines
          headers = path == tar_audit ? lines.drop(lines.rindex { |line| line.start_with?("BEGIN ") } || 0) : lines.last(12)
          diagnostics += "\n#{File.basename(path)}:\n#{headers.join}"
        end
      end
      raise "CLI #{arguments.first}: expected success=#{allowed}; #{diagnostics}:\n#{output}"
    end
    puts output
    output
  end
  cli.call("init-env", "--host", "proof.example.invalid", "--acme-email", "proof@example.invalid", "--output", private_env)
  env_text = run.call("sudo", "-n", "cat", private_env)
  secrets.concat(env_text.scan(/NAVISHAI_(?:DATABASE_PASSWORD|POSTGRES_PASSWORD|PREPARE_PASSWORD|SECRET_KEY_BASE|BOOTSTRAP_TOKEN)='([^']+)'/).flatten)
  env_text = env_text.gsub("NAVISHAI_SYSTEM_SMTP_ADDRESS=''", "NAVISHAI_SYSTEM_SMTP_ADDRESS='smtp.example.invalid'")
    .gsub("NAVISHAI_SYSTEM_SMTP_PORT=''", "NAVISHAI_SYSTEM_SMTP_PORT='2525'")
    .gsub("NAVISHAI_SYSTEM_SMTP_USER_NAME=''", "NAVISHAI_SYSTEM_SMTP_USER_NAME='synthetic'")
    .gsub("NAVISHAI_SYSTEM_SMTP_PASSWORD=''", "NAVISHAI_SYSTEM_SMTP_PASSWORD='synthetic-mail-only'")
    .gsub("NAVISHAI_SYSTEM_SMTP_FROM=''", "NAVISHAI_SYSTEM_SMTP_FROM='proof@example.invalid'")
  run.call("sudo", "-n", "tee", private_env, input: env_text)
  # Capture only event metadata, never container environments/commands or credentials.
  events = File.join(directory, "events.jsonl")
  event_command = docker.drop(2) + [ "events", "--filter", "type=container", "--filter", "label=com.docker.compose.project=navishai-reset", "--filter", "event=start", "--format", "{{json .}}" ]
  normalized = JSON.parse(run.call("sudo", "-n", "env", "VPS_IMAGE=navishai-reset:#{release1}", *docker.drop(2), "compose",
    "--project-name", "navishai-reset", "--project-directory", source, "--env-file", private_env,
    "--file", File.join(source, "compose.yaml"), "--file", File.join(source, "ops/vps/compose.yaml"), "config", "--format", "json"))
  %w[web jobs].each do |name|
    definition = normalized.fetch("services").fetch(name)
    raise "Compose kept runtime networks/ports" unless definition.fetch("network_mode") == "service:app-net" && definition["networks"].to_h.empty? && Array(definition["ports"]).empty?
  end
  puts "PASS: real Compose 2.39.4 normalized web/jobs share service:app-net without inherited networks/ports."
  start_service.call("events", [ "sudo", "-n", "sh", "-ec", "exec #{Shellwords.join(event_command)} >> #{events}" ])
  puts "INSTALL: actual archive/build/pinned pulls/roles/preparation/systemctl startup child."
  cli.call("install", "--source", source, "--commit", release1, "--env", private_env)
  raise "Installer did not hand startup to generated systemctl child" unless run.call("sudo", "-n", "cat", systemctl_log).include?("start navishai-reset.service navishai-reset-check.timer")
  containers = lambda do
    ids = run.call(*docker, "ps", "-aq", "--filter", "label=com.docker.compose.project=navishai-reset").split
    ids.empty? ? [] : JSON.parse(run.call(*docker, "inspect", *ids))
  end
  service_info = ->(name) { containers.call.find { |info| info.fetch("Config").fetch("Labels")["com.docker.compose.service"] == name && info.fetch("State").fetch("Running") } || raise("Missing running #{name}") }
  writers_stopped = lambda do
    running = containers.call.select { |info| %w[web jobs proxy].include?(info.fetch("Config").fetch("Labels")["com.docker.compose.service"]) && info.fetch("State").fetch("Running") }
    raise "Writer window: #{running.map { |info| info.fetch('Name') }}" unless running.empty?
  end
  pg = service_info.call("postgres").fetch("Id")
  web = service_info.call("web").fetch("Id")
  proxy = service_info.call("proxy").fetch("Id")
  wait.call("Caddy internal CA") { run.call(*docker, "cp", "#{proxy}:/data/caddy/pki/authorities/local/root.crt", ca); true }
  cli.call("check")
  wait.call("trusted Caddy HTTPS") { run.call(*cli_prefix, "status"); true }
  cli.call("status")
  %w[app-net web jobs postgres proxy].each do |name|
    info = service_info.call(name)
    raise "Automatic Docker restart: #{name}" unless info.fetch("HostConfig").fetch("RestartPolicy").fetch("Name") == "no"
  end
  %w[web jobs].each do |name|
    info = service_info.call(name)
    raise "Namespace sharing" unless info.fetch("HostConfig").fetch("NetworkMode") == "container:#{service_info.call('app-net').fetch('Id')}"
    raise "UID/capability controls" unless info.fetch("Config").fetch("User") == "1000:1000" && info.fetch("HostConfig").fetch("CapDrop") == [ "ALL" ]
  end
  databases = %w[navishai_lab_production navishai_lab_production_cache navishai_lab_production_queue navishai_lab_production_cable]
  sql = lambda do |database, query|
    run.call(*docker, "exec", pg, "psql", "-X", "--no-psqlrc", "-v", "ON_ERROR_STOP=1", "-U", "navishai_admin", "-d", database, "-At", "-c", query).strip
  end
  raise "Restricted roles" unless sql.call(databases.first, "SELECT rolname||':'||rolsuper||':'||rolcreatedb||':'||rolcreaterole||':'||rolreplication||':'||rolbypassrls FROM pg_roles WHERE rolname IN ('navishai','navishai_setup') ORDER BY rolname") == "navishai:false:false:false:false:false\nnavishai_setup:false:false:false:false:false"
  databases.each do |database|
    raise "Database owner #{database}" unless sql.call(database, "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()") == "navishai_setup"
    raise "Schema owner #{database}" unless sql.call(database, "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='public'") == "navishai_setup"
  end
  puts run.call(*docker, "exec", "-i", web, "bin/rails", "runner", "-", input: File.read(File.join(root, "test/support/container_runtime_proof.rb")))
  verification = <<~'RUBY'
    require Rails.root.join("ops/current_workflows_proof")
    analysis = CorpusAnalysis.find(File.read(Rails.root.join("tmp/proof-analysis-id")))
    abort "Analysis still processing/wrong partition" unless analysis.state == "complete" && analysis.summary.fetch("conversations") == 2 && analysis.summary.fetch("clusters") == 2
    manifest = JSON.parse(File.read(Rails.root.join("tmp/proof-optional-requests.json")))
    abort "Optional jobs still queued" unless Operations::CurrentWorkflowsProof.verify_queued(manifest)
    puts "PASS: separate native jobs finish local analysis and refuse optional disclosures under empty registries."
  RUBY
  wait.call("separate native jobs") { run.call(*docker, "exec", "-i", web, "bin/rails", "runner", "-", input: verification); true }
  puts run.call(*docker, "exec", "-i", web, "bin/rails", "runner", "-", input: verification)
  analysis_id = Integer(run.call(*docker, "exec", web, "cat", "/rails/tmp/proof-analysis-id"))
  optional_manifest = run.call(*docker, "exec", web, "cat", "/rails/tmp/proof-optional-requests.json")
  verify_history = lambda do
    container = service_info.call("web").fetch("Id")
    run.call(*docker, "exec", "-i", container, "bin/rails", "runner", "-", analysis_id.to_s, optional_manifest, input: <<~'RUBY')
      require Rails.root.join("ops/current_workflows_proof")
      analysis = CorpusAnalysis.find(ARGV.fetch(0))
      abort "Lost local analysis" unless analysis.state == "complete" && analysis.summary.fetch("clusters") == 2
      abort "Disclosure receipt changed/requeued" unless Operations::CurrentWorkflowsProof.verify_queued(JSON.parse(ARGV.fetch(1)))
      valid = ActiveRecord::Base.configurations.configs_for(env_name: "production").all? do |config|
        ActiveRecord::Base.establish_connection(config)
        connection = ActiveRecord::Base.connection
        next false unless connection.select_value("SELECT current_user") == "navishai"
        begin
          connection.execute("CREATE TABLE forbidden_runtime_restart(id integer)")
          abort "Runtime DDL accepted after recovery"
        rescue ActiveRecord::StatementInvalid => error
          raise unless error.cause.is_a?(PG::InsufficientPrivilege)
        end
        true
      end
      abort "Wrong four-DB runtime roles" unless valid
      puts "PASS: four-DB runtime role/DDL denial and fixed complete/interrupted native history survive without resend."
    RUBY
  end
  puts verify_history.call
  puts "PASS: actual install/child lock handoff, all four database/schema owners, restricted owner/runtime and runtime privilege denials, trusted internal-CA Caddy HTTPS."
  holder = service_info.call("app-net")
  holder_namespace = [ "sudo", "-n", "nsenter", "--net=/proc/#{holder.fetch('State').fetch('Pid')}/ns/net" ]
  run.call(*holder_namespace, "ip6tables", "-I", "OUTPUT", "1", "-j", "ACCEPT")
  cli.call("check", allowed: false)
  writers_stopped.call
  cli.call("start")
  raise "Startup reused shadowed namespace" if service_info.call("app-net").fetch("Id") == holder.fetch("Id")
  cli.call("check")
  holder = service_info.call("app-net")
  cli.call("stop")
  writers_stopped.call
  release_path = File.join(managed, "opt/navishai-reset/releases", release1)
  compose = [ *docker, "compose", "--project-name", "navishai-reset", "--project-directory", release_path, "--env-file", File.join(managed, "etc/navishai-reset/env"), "--file", File.join(release_path, "compose.yaml"), "--file", File.join(release_path, "ops/vps/compose.yaml") ]
  run.call("sudo", "-n", "env", "VPS_IMAGE=navishai-reset:#{release1}", *compose.drop(2), "up", "-d", "--no-deps", "--wait", "--force-recreate", "app-net", "postgres")
  raise "Holder unchanged" if service_info.call("app-net").fetch("Id") == holder.fetch("Id")
  raise "Postgres unchanged" if service_info.call("postgres").fetch("Id") == pg
  addresses4 = %w[93.184.216.34 169.254.169.254 100.64.1.2 198.18.0.1]
  addresses6 = %w[2001:4860:feed::1 fd00:feed::1 2001:db8::1 2002::1]
  addresses4.each { |ip| run.call(*namespace, "ip", "addr", "add", "#{ip}/32", "dev", "lo") }
  addresses6.each { |ip| run.call(*namespace, "ip", "-6", "addr", "add", "#{ip}/128", "dev", "lo", "nodad") }
  start_service.call("peer", namespace + [ RbConfig.ruby, File.join(root, "test/support/vps_policy_peer.rb"), "9443" ])
  probe = lambda do |container, address, allowed|
    run.call(*docker, "exec", container, "ruby", "-rsocket", "-rtimeout", "-e", <<~'RUBY', address, allowed.to_s)
      address, allowed = ARGV
      begin
        Timeout.timeout(3) { TCPSocket.open(address, 9443) { |socket| socket.puts("probe"); abort "Echo" unless socket.gets == "probe\n" } }
        abort "Forbidden destination reachable: #{address}" unless allowed == "true"
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH
        abort "Allowed destination denied: #{address}" unless allowed == "false"
      end
    RUBY
  end
  unguarded = service_info.call("app-net").fetch("Id")
  wait.call("synthetic echo") { probe.call(unguarded, addresses4.first, true); true }
  [ *addresses4, *addresses6 ].each { |ip| probe.call(unguarded, ip, true) }
  cli.call("check", allowed: false)
  writers_stopped.call
  cli.call("start")
  cli.call("check")
  %w[web jobs].each do |name|
    container = service_info.call(name).fetch("Id")
    probe.call(container, addresses4.first, true)
    probe.call(container, addresses6.first, true)
    [ *addresses4.drop(1), *addresses6.drop(1) ].each { |ip| probe.call(container, ip, false) }
  end
  holder = service_info.call("app-net")
  holder_namespace = [ "sudo", "-n", "nsenter", "--net=/proc/#{holder.fetch('State').fetch('Pid')}/ns/net" ]
  %w[iptables ip6tables].each do |family|
    counters = run.call(*holder_namespace, family, "-L", "NAVISHAI_OUTPUT", "-v", "-n", "-x")
    raise "No #{family} kernel rejection" unless counters.lines.any? { |line| line.include?("REJECT") && line.split.first.to_i.positive? }
  end
  puts "PASS: shadowed IPv6 policy fails check with writers stopped; start replaces the namespace before reapply; real holder/PostgreSQL replacement requires reapply before workloads."
  puts "PASS: same synthetic IPv4/IPv6 peers reachable before policy, kernel-denied afterwards from actual web/jobs; public echoes, PostgreSQL, Docker DNS and Caddy ingress replies still work."
  # Recovery/upgrade assertions follow the exact CLI source contract, not separate recovery helpers.
  pg = service_info.call("postgres").fetch("Id")
  web = service_info.call("web").fetch("Id")
  cli.call("stop")
  writers_stopped.call
  databases.each do |database|
    sql.call(database, "SET ROLE navishai_setup; CREATE TABLE proof_checkpoint_rows(id bigserial PRIMARY KEY, marker text NOT NULL); INSERT INTO proof_checkpoint_rows(marker) VALUES ('retained-alpha'),('retained-omega'); SELECT setval('proof_checkpoint_rows_id_seq',47,false); GRANT SELECT,INSERT,UPDATE,DELETE ON proof_checkpoint_rows TO navishai; GRANT USAGE,SELECT ON proof_checkpoint_rows_id_seq TO navishai")
  end
  checkpoint_state = lambda do
    databases.to_h do |database|
      [ database, sql.call(database, <<~SQL) ]
        SELECT json_build_object(
          'rows',(SELECT json_agg(t ORDER BY id) FROM proof_checkpoint_rows t),
          'sequence',(SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM proof_checkpoint_rows_id_seq),
          'objects',(SELECT json_agg(json_build_array(c.relname,pg_get_userbyid(c.relowner),c.relacl::text) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'),
          'defaults',(SELECT json_agg(json_build_array(pg_get_userbyid(defaclrole),defaclobjtype,defaclacl::text) ORDER BY defaclrole,defaclobjtype) FROM pg_default_acl),
          'schema',(SELECT json_build_array(pg_get_userbyid(nspowner),nspacl::text) FROM pg_namespace WHERE nspname='public'));
      SQL
    end
  end
  before_restore = checkpoint_state.call
  storage_value = "Synthetic retained storage #{SecureRandom.hex(8)}"
  # Stopped containers cannot exec; use a real one-off in the already guarded holder namespace.
  marker_command = compose + [ "run", "--rm", "--no-deps", "web", "ruby", "-e", 'File.write("/rails/storage/vps-proof-marker", ARGV.fetch(0))', storage_value ]
  run.call("sudo", "-n", "env", "VPS_IMAGE=navishai-reset:#{release1}", *marker_command.drop(2))
  env_path = File.join(managed, "etc/navishai-reset/env")
  env_before = run.call("sudo", "-n", "sha256sum", env_path).split.first
  checkpoint = File.join(directory, "checkpoint")
  cli.call("backup", "--output", checkpoint)
  cli.call("check")
  manifest = File.join(checkpoint, "CHECKSUMS")
  digest = run.call("sudo", "-n", "sha256sum", manifest).split.first
  raise "Backup payload checksums missing" unless digest.match?(/\A[0-9a-f]{64}\z/)
  cli.call("stop")
  writers_stopped.call
  databases.each { |database| sql.call(database, "CREATE TABLE proof_later_mutation(id integer); INSERT INTO proof_later_mutation VALUES (17); UPDATE proof_checkpoint_rows SET marker='later-change'; SELECT setval('proof_checkpoint_rows_id_seq',93,true)") }
  run.call("sudo", "-n", "tee", env_path, input: env_text.sub("smtp.example.invalid", "later.example.invalid"))
  changed_marker = compose + [ "run", "--rm", "--no-deps", "web", "ruby", "-e", 'File.write("/rails/storage/vps-proof-marker", "later-storage")' ]
  run.call("sudo", "-n", "env", "VPS_IMAGE=navishai-reset:#{release1}", *changed_marker.drop(2))
  cli.call("restore", "--from", checkpoint, "--confirm-restore", digest)
  writers_stopped.call
  pg = service_info.call("postgres").fetch("Id")
  databases.each { |database| raise "Restore did not restore #{database}" unless sql.call(database, "SELECT to_regclass('public.proof_later_mutation') IS NULL") == "t" }
  raise "Restored rows/sequence/owner/ACL/default ACL differ" unless checkpoint_state.call == before_restore
  raise "Restored private env differs" unless run.call("sudo", "-n", "sha256sum", env_path).split.first == env_before
  cli.call("start")
  cli.call("check")
  web = service_info.call("web").fetch("Id")
  raise "Restored Rails storage differs" unless run.call(*docker, "exec", web, "cat", "/rails/storage/vps-proof-marker") == storage_value
  puts verify_history.call
  puts "PASS: actual joined backup/digest-confirmed restore recover all four DB rows/sequences/owners/ACL/default ACL, private env and Rails storage; restore leaves writers stopped."
  # Add a harmless real code revision, then run the actual archive/build/migrate/upgrade path.
  run.call("sudo", "-n", "tee", File.join(source, "ops/vps/proof-release"), input: "Synthetic release two\n")
  run.call("sudo", "-n", "chown", "-R", Etc.getpwuid.uid.to_s, source)
  release2 = commit_source.call("test: synthetic successful upgrade")
  run.call("sudo", "-n", "chown", "-R", "root:root", source)
  upgrade_backup = File.join(directory, "upgrade-backup")
  cli.call("upgrade", "--source", source, "--commit", release2, "--backup", upgrade_backup)
  cli.call("check")
  receipt = JSON.parse(run.call("sudo", "-n", "cat", File.join(managed, "var/lib/navishai-reset/install.json")))
  raise "Upgrade release identity" unless receipt.fetch("commit") == release2
  run.call("sudo", "-n", "tee", File.join(source, "db/migrate/20261003000000_vps_proof_failure.rb"), input: <<~'RUBY')
    class VpsProofFailure < ActiveRecord::Migration[8.1]
      disable_ddl_transaction!

      def change
        # A code-only rollback must fail: these changes survive migration failure.
        execute "UPDATE proof_checkpoint_rows SET marker='failed-candidate-change'"
        execute "SELECT setval('proof_checkpoint_rows_id_seq',97,true)"
        raise "Synthetic candidate migration failure"
      end
    end
  RUBY
  run.call("sudo", "-n", "chown", "-R", Etc.getpwuid.uid.to_s, source)
  release3 = commit_source.call("test: synthetic failed upgrade for rollback proof")
  run.call("sudo", "-n", "chown", "-R", "root:root", source)
  rollback_backup = File.join(directory, "rollback-backup")
  failure = cli.call("upgrade", "--source", source, "--commit", release3, "--backup", rollback_backup, allowed: false)
  raise "Wrong candidate failure" unless failure.include?("Synthetic candidate migration failure") && failure.include?("old full recovery point restored")
  writers_stopped.call
  receipt = JSON.parse(run.call("sudo", "-n", "cat", File.join(managed, "var/lib/navishai-reset/install.json")))
  raise "Rollback release identity" unless receipt.fetch("commit") == release2
  pg = service_info.call("postgres").fetch("Id")
  raise "Rollback lost rows/owner/ACL/default ACL" unless checkpoint_state.call == before_restore
  cli.call("start")
  cli.call("check")
  puts verify_history.call
  puts "PASS: successful real upgrade and failed-migration full rollback restore prior source/image/config/four-DB point, with writers stopped until explicit start."
  audits = run.call("sudo", "-n", "cat", docker_audit).lines.map { |line| JSON.parse(line) }
  staged_checks = run.call("sudo", "-n", "cat", staged_audit).lines.map { |line| JSON.parse(line) }
  raise "Actual pre-start runtime inspections not observed" unless %w[web jobs].all? { |service| staged_checks.any? { |check| check.fetch("service") == service } }
  puts "PASS: #{staged_checks.size} actual pre-start inspections preserve running holder/PostgreSQL IDs and keep web/jobs Running=false until explicit start."
  started_writers = run.call("sudo", "-n", "cat", events).lines.map { |line| JSON.parse(line) }.select do |event|
    attributes = event.fetch("Actor").fetch("Attributes")
    %w[web jobs proxy].include?(attributes["com.docker.compose.service"]) && attributes["com.docker.compose.oneoff"] == "False"
  end
  raise "No maintenance windows audited" if audits.empty?
  audits.each_slice(2) do |before, after|
    raise "Incomplete maintenance audit" unless before.fetch("phase") == "before" && after&.fetch("phase") == "after"
    raise "Workload started during maintenance" if started_writers.any? { |event| event.fetch("timeNano").between?(before.fetch("timeNano"), after.fetch("timeNano")) }
  end
  puts "PASS: #{audits.size / 2} actual preparation/staging/dump/restore/storage maintenance windows have no live writers at either boundary and no Docker workload-start event within them."
  cli.call("stop")
  stop_service.call("run")
  start_service.call("run", daemon_command)
  wait.call("daemon restarted") { run.call(*docker, "info"); true }
  raise "Docker automatic startup window" unless run.call(*docker, "ps", "--quiet").strip.empty?
  cli.call("start")
  cli.call("check")
  puts verify_history.call
  puts "PASS: real daemon restart has no automatic workload-start window; actual CLI reapplies namespace policy."
ensure
  clean = lambda do |*command|
    run.call(*command)
  rescue StandardError => error
    cleanup_errors << error.message
    nil
  end
  if docker
    ids = clean.call(*docker, "ps", "-aq").to_s.split
    clean.call(*docker, "rm", "--force", *ids) unless ids.empty?
  end
  services.reverse_each { |name| clean.call("amp", "orb", "service", "stop", name) }
  clean.call("findmnt", "--raw", "--noheadings", "--output", "TARGET").to_s.lines.map(&:strip)
    .select { |path| path.start_with?("#{directory}/") }.sort_by(&:length).reverse_each { |path| clean.call("sudo", "-n", "umount", path) }
  clean.call("sudo", "-n", "rm", "-rf", "--", directory) if cleanup_errors.empty?
  raise "Cleanup failed in #{directory}: #{cleanup_errors.join('; ')}" unless cleanup_errors.empty?
  raise "Host firewall/sysctl changed" unless host == host_snapshot.call
  puts "CLEAN: private daemons/containers/volumes/images/namespaces/source/managed root removed; host IPv4/IPv6 firewall and checked sysctls unchanged."
end
puts "LIMIT: isolated orb, simulated systemd registration/child dispatch and internal-CA HTTPS; no real reboot/public DNS/ACME/SMTP/VPS/provider/customer acceptance."
