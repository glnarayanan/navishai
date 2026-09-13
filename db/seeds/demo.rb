module DemoSeed
  ORGANIZATION_SLUG = "navishai-demo"
  WORKSPACE_SLUG = "customer-operations"

  def self.load!
    return if Organization.joins(:workspaces).exists?(slug: ORGANIZATION_SLUG, workspaces: { slug: WORKSPACE_SLUG })

    password = ENV["NAVISHAI_DEMO_PASSWORD"].presence
    if Rails.env.production? && password.blank?
      raise "NAVISHAI_DEMO_PASSWORD is required when seeding a production demo"
    end

    ActiveRecord::Base.transaction do
      organization = Organization.create!(name: "NavishAI Demo", slug: ORGANIZATION_SLUG)
      workspace = organization.workspaces.create!(name: "Customer Operations", slug: WORKSPACE_SLUG)
      owner = User.create!(
        email_address: ENV.fetch("NAVISHAI_DEMO_EMAIL", "owner@demo.navishai.local"),
        password: password || "navishai-demo-password", verified_at: Time.current
      )
      membership = workspace.memberships.create!(user: owner, role: :owner)

      AccountDataImport.import_api!(workspace:, membership:, rows: [ {
        source_id: "demo-northstar", account_name: "Northstar Labs", account_domain: "northstar.example",
        contact_name: "Maya Chen", contact_email: "maya@northstar.example",
        renewal_on: (Date.current + 45.days).iso8601, contract_value: 72_000,
        active_users: 38, licensed_seats: 50
      } ])
      account = workspace.accounts.find_by!(name: "Northstar Labs")
      contact = account.contacts.find_by!(name: "Maya Chen")

      seed_support_case!(workspace:, membership:, contact:)
      seed_waiting_case!(workspace:, membership:, contact:)
      seed_scorecard!(workspace:, membership:)
    end
  end

  def self.seed_support_case!(workspace:, membership:, contact:)
    message = ConversationThread.start_inbound!(
      workspace:, contact:, subject: "SSO access fails for the onboarding team",
      body: "Our new teammates see an access denied page after signing in. Can you help before tomorrow's rollout?",
      occurred_at: 35.minutes.ago, source: :integration
    )
    support_case = message.conversation.support_case
    CaseWorkflow.transition!(
      workspace:, support_case:, membership:, to: :triaged,
      reason: "Access issue confirmed", occurred_at: 30.minutes.ago
    )
    CaseWorkflow.transition!(
      workspace:, support_case:, membership:, to: :investigating,
      reason: "Reviewing identity configuration", occurred_at: 25.minutes.ago
    )
    CaseWorkflow.prioritize!(workspace:, support_case:, membership:, priority: :urgent)
    CaseWorkflow.assign!(workspace:, support_case:, membership:, assignee: membership)
    tag = CaseWorkflow.create_tag!(workspace:, membership:, name: "Access")
    CaseWorkflow.tag!(workspace:, support_case:, membership:, tag:)
    CaseWorkflow.add_note!(
      workspace:, support_case:, membership:,
      body: "Compare the tenant claim with the current identity-provider mapping. Do not ask for credentials."
    )
  end
  private_class_method :seed_support_case!

  def self.seed_waiting_case!(workspace:, membership:, contact:)
    message = ConversationThread.start_inbound!(
      workspace:, contact:, subject: "Weekly usage export",
      body: "Could the report include workspace names alongside active-user counts?",
      occurred_at: 2.hours.ago, source: :integration
    )
    support_case = message.conversation.support_case
    CaseWorkflow.transition!(
      workspace:, support_case:, membership:, to: :triaged,
      reason: "Request understood", occurred_at: 110.minutes.ago
    )
    CaseWorkflow.transition!(
      workspace:, support_case:, membership:, to: :investigating,
      reason: "Checking export fields", occurred_at: 105.minutes.ago
    )
    CaseWorkflow.transition!(
      workspace:, support_case:, membership:, to: :waiting_customer,
      reason: "Need the preferred report format", occurred_at: 90.minutes.ago
    )
  end
  private_class_method :seed_waiting_case!

  def self.seed_scorecard!(workspace:, membership:)
    AccountHealth.recalculate!(
      workspace:, account: workspace.accounts.find_by!(name: "Northstar Labs"),
      trigger_kind: "human_request", membership:
    )
    current = workspace.health_scorecard.current_version
    version = HealthScorecardDesigner.propose!(
      workspace:, membership:, prompt: "Give unresolved support work more weight before renewal.",
      healthy_min: 80, watch_min: 55,
      weights: HealthScorecardDefinition.default.fetch("rules").to_h do |rule|
        [ rule.fetch("signal_key"), rule.fetch("signal_key") == "open_cases" ? 35 : rule.fetch("weight") ]
      end
    )
    HealthScorecardBacktester.run!(workspace:, membership:, version:)
    HealthScorecardPublisher.publish!(
      workspace:, membership:, version:, expected_current_version_id: current.id,
      expected_backtest_id: version.backtests.order(generated_at: :desc, id: :desc).pick(:id)
    )
  end
  private_class_method :seed_scorecard!
end
