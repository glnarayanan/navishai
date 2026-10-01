# Synthetic operations payload shared by the socket and Compose proofs.
raise "UID" unless Process.uid == 1000
status = File.read("/proc/self/status")
raise "Effective capabilities" unless status[/^CapEff:\s+(\w+)/, 1].to_i(16).zero?
raise "Privilege escalation" unless status[/^NoNewPrivs:\s+(\d+)/, 1] == "1"
raise "Administrator secret entered runtime" if %w[POSTGRES_PASSWORD NAVISHAI_POSTGRES_PASSWORD NAVISHAI_DATABASE_USERNAME NAVISHAI_PREPARE_PASSWORD].any? { |key| ENV.key?(key) }
%w[NAVISHAI_EVALUATION_ENDPOINTS NAVISHAI_SCENARIO_ENDPOINTS NAVISHAI_CORPUS_ENDPOINTS NAVISHAI_MATCHING_ENDPOINTS NAVISHAI_IMPACT_ENDPOINTS NAVISHAI_TRACE_DISCOVERY_ENDPOINTS].each { |key| raise "Disclosure registry" unless ENV.fetch(key) == "[]" }
connection = ActiveRecord::Base.connection
raise "Runtime role" unless connection.select_value("SELECT current_user") == "navishai"
%w[rolsuper rolcreatedb rolcreaterole rolreplication rolbypassrls].each { |flag| raise flag if connection.select_value("SELECT #{flag} FROM pg_roles WHERE rolname = current_user") }
[ "ALTER TABLE audit_events DISABLE TRIGGER ALL", "ALTER TABLE corpus_items DISABLE TRIGGER ALL", "CREATE TABLE forbidden_runtime (id integer)", "CREATE ROLE forbidden_runtime", "CREATE DATABASE forbidden_runtime", "SET ROLE navishai_setup" ].each do |sql|
  begin
    connection.execute(sql)
    raise "Prohibited SQL accepted: #{sql}"
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.cause.is_a?(PG::InsufficientPrivilege)
  end
end
organization = Organization.create!(name: "Synthetic runtime proof", slug: "synthetic-runtime")
workspace = organization.workspaces.create!(name: "Synthetic lab", slug: "synthetic-lab")
user = User.create!(email_address: "synthetic-runtime@example.invalid", password: SecureRandom.hex(24), verified_at: Time.current)
membership = workspace.memberships.create!(user:, role: "owner")
corpus = workspace.corpora.create!(name: "Synthetic SSO corpus")
records = [ { id: "sso", title: "Certificate rotation", content: "SSO certificate expired; ask for metadata before changing configuration." },
  { id: "api", title: "API outage", content: "Critical production API requests return 500; escalate to Engineering with logs." } ]
CorpusIntake.call(corpus:, membership:, name: "Synthetic conversations", kind: "conversations", bytes: records.to_json)
CorpusIntake.call(corpus:, membership:, name: "Synthetic policy", kind: "document", bytes: "Ask for certificate expiry before changing configuration. Engineering needs reproducible API logs.")
analysis = CorpusAnalysis.request!(corpus:, membership:, scenario_limit: 2)
File.write(Rails.root.join("tmp/proof-analysis-id"), analysis.id)
require Rails.root.join("ops/current_workflows_proof")
requests = Operations::CurrentWorkflowsProof.seed(execute: false, membership:)
File.write(Rails.root.join("tmp/proof-optional-requests.json"), JSON.generate(requests), perm: 0o600)
raise "Cache write" unless Rails.cache.write("synthetic-proof", "local-only")
raise "Cache read" unless Rails.cache.read("synthetic-proof") == "local-only"
SolidCable::Message.count
begin
  connection.execute("UPDATE audit_events SET action = action")
  raise "Audit rewrite accepted"
rescue ActiveRecord::StatementInvalid => error
  raise unless error.cause.is_a?(PG::RaiseException) && error.cause.message.include?("append-only")
end
puts "PASS: UID 1000, empty disclosure registries, non-owner role, six privilege denials, intake, audit immutability and separate queue/cache/cable access."
