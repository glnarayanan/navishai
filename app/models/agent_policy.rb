class AgentPolicy
  TOOLS = {
    "conversation_read" => "Read conversations",
    "case_read" => "Read cases",
    "account_read" => "Read accounts",
    "knowledge_search" => "Search approved knowledge",
    "public_web_search" => "Search the public web",
    "draft_propose" => "Propose a customer draft",
    "note_propose" => "Propose an internal note",
    "review_record" => "Record a policy review"
  }.freeze
  RUNTIME_PROFILES = {
    "workspace_default" => "Workspace default",
    "thorough" => "Thorough",
    "fast" => "Fast"
  }.freeze
  REVIEW_POLICIES = {
    "required" => "Review every result",
    "on_policy_flag" => "Review when policy flags risk"
  }.freeze
  ROLE_DEFINITIONS = {
    "support_coordinator" => {
      crew_kind: "support", name: "Coordinator / Triage",
      instructions: "Classify the case, surface urgency and missing facts, and choose only the specialists needed.",
      tools: %w[case_read conversation_read]
    },
    "support_investigator" => {
      crew_kind: "support", name: "Investigator",
      instructions: "Investigate the case against current conversation facts and approved evidence. State uncertainty and do not invent facts.",
      tools: %w[case_read conversation_read knowledge_search public_web_search]
    },
    "resolution_drafter" => {
      crew_kind: "support", name: "Resolution Drafter",
      instructions: "Propose a plain-language resolution grounded in cited evidence. Never send or schedule a customer message.",
      tools: %w[case_read conversation_read draft_propose knowledge_search]
    },
    "support_reviewer" => {
      crew_kind: "support", name: "Policy / Quality Reviewer",
      instructions: "Check evidence, policy, stale sources, conflicts, and unsupported claims before human review.",
      tools: %w[case_read conversation_read knowledge_search review_record]
    },
    "account_analyst" => {
      crew_kind: "customer_success", name: "Account Analyst",
      instructions: "Summarise current account facts and deterministic health signals without turning inference into fact.",
      tools: %w[account_read conversation_read]
    },
    "risk_investigator" => {
      crew_kind: "customer_success", name: "Risk Investigator",
      instructions: "Investigate material risk changes, likely causes, evidence, and uncertainty within the account scope.",
      tools: %w[account_read conversation_read knowledge_search public_web_search]
    },
    "success_strategist" => {
      crew_kind: "customer_success", name: "Success Strategist",
      instructions: "Propose bounded, evidence-backed interventions for a human owner. Never contact a customer.",
      tools: %w[account_read knowledge_search note_propose]
    },
    "success_reviewer" => {
      crew_kind: "customer_success", name: "Policy / Quality Reviewer",
      instructions: "Check evidence, policy, stale sources, conflicts, and unsupported claims before human review.",
      tools: %w[account_read knowledge_search review_record]
    }
  }.freeze

  def self.definition(role_key)
    ROLE_DEFINITIONS.fetch(role_key.to_s)
  end

  def self.tools_for(role_key)
    definition(role_key).fetch(:tools)
  end
end
