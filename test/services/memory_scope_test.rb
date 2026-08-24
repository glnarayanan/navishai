require "test_helper"

class MemoryScopeTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:acme_support)
    CrewConfiguration.install_defaults!(workspace: @workspace)
    @account = accounts(:acme)
    @contact = contacts(:alice)
    @conversation = Conversation.create!(workspace: @workspace, contact: @contact, subject: "Memory scope", started_at: Time.current)
    @support_case = SupportCase.create!(
      workspace: @workspace, conversation: @conversation, status: :new, priority: :normal, status_changed_at: Time.current
    )
    @crew = @workspace.crew_templates.first
    @agent = @crew.agent_profiles.first
    @user = users(:owner)
  end

  test "inherits only matching scopes inside the current workspace" do
    organization = create_memory(scope_kind: "organization", organization: @workspace.organization)
    workspace = create_memory(scope_kind: "workspace")
    account = create_memory(scope_kind: "account", account: @account)
    contact = create_memory(scope_kind: "contact", contact: @contact)
    support_case = create_memory(scope_kind: "support_case", support_case: @support_case)
    crew = create_memory(scope_kind: "crew", crew_template: @crew)
    agent = create_memory(scope_kind: "agent", agent_profile: @agent)
    user = create_memory(scope_kind: "user", user: @user)
    foreign = create_memory(workspace: workspaces(:beta_support), scope_kind: "workspace")

    records = MemoryScope.resolve(context: MemoryScope::Context.new(
      workspace: @workspace, support_case: @support_case, agent_profile: @agent, user: @user
    ))

    assert_equal [ organization, workspace, account, contact, support_case, crew, agent, user ].map(&:id).sort,
      records.pluck(:id).sort
    assert_not_includes records, foreign
  end

  test "denies cross-workspace targets and users without membership" do
    assert_raises(ArgumentError) do
      MemoryScope.resolve(context: MemoryScope::Context.new(workspace: @workspace, account: accounts(:beta)))
    end
    assert_raises(ArgumentError) do
      MemoryScope.resolve(context: MemoryScope::Context.new(workspace: @workspace, user: users(:outsider)))
    end
    assert_raises(ArgumentError) do
      MemoryScope.resolve(context: MemoryScope::Context.new(
        workspace: @workspace, contact: @contact, account: accounts(:acme_duplicate)
      ))
    end
  end

  private
    def create_memory(workspace: @workspace, **scope)
      now = Time.current
      MemoryRecord.create!(
        workspace: workspace,
        memory_type: "episodic",
        topic: SecureRandom.uuid,
        content: "Scoped memory",
        authority: "source_record",
        origin_kind: "system",
        source_reference: "case-event://#{SecureRandom.uuid}",
        source_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
        observed_at: now,
        valid_from: now,
        confidence: 1,
        retention_policy: "indefinite",
        **scope
      )
    end
end
