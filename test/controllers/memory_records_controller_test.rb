require "test_helper"

class MemoryRecordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @owner = memberships(:owner_support)
    @memory = @workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "account-policy",
      content: "Accounts require an owner review.", authority: :source_record, origin_kind: :system,
      source_reference: "test://account-policy", source_digest: Digest::SHA256.hexdigest("policy"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
    )
  end

  test "a manager inspects, filters, corrects, and deletes with user audits" do
    sign_in_as users(:owner)

    assert_difference -> { AuditEvent.where(action: "memory.library_inspected").count }, 1 do
      get workspace_memory_records_path(@workspace), params: { type: "semantic", state: "current" }
    end
    assert_response :success
    assert_select "h1", "Workspace memory"
    assert_select ".memory-record-list", text: /Accounts require an owner review/
    audit = AuditEvent.where(action: "memory.library_inspected").last
    assert_equal users(:owner), audit.actor
    assert_equal({ "access_scope" => "all", "record_count" => 1 }, audit.metadata)

    assert_difference -> { AuditEvent.where(action: "memory.record_inspected").count }, 1 do
      get workspace_memory_record_path(@workspace, @memory)
    end
    assert_response :success
    assert_select "#propose-correction-title", "Publish a correction"
    assert_select "#delete-memory-title"

    assert_difference "MemoryRecord.count", 1 do
      post workspace_memory_record_corrections_path(@workspace, @memory), params: {
        memory_correction: {
          content: "Accounts require Manager review.", confidence: "0.9", retention_policy: "indefinite"
        }
      }
    end
    assert_redirected_to workspace_memory_record_path(@workspace, @memory)
    assert @memory.reload.revisions.sole.authority_human_correction?

    delete workspace_memory_record_path(@workspace, @memory), params: { reason: "Superseded source removed" }
    assert_redirected_to workspace_memory_record_path(@workspace, @memory)
    assert @memory.reload.memory_tombstone
  end

  test "members see only memory used in owned work while viewers and foreign paths fail closed" do
    member = @workspace.memberships.create!(
      user: User.create!(email_address: "memory-controller-member@example.com", password: "password12345", verified_at: Time.current),
      role: :member
    )
    hidden = @workspace.memory_records.create!(
      memory_type: :semantic, scope_kind: :workspace, topic: "hidden",
      content: "Hidden from unlinked members.", authority: :source_record, origin_kind: :system,
      source_reference: "test://hidden", source_digest: Digest::SHA256.hexdigest("hidden"),
      observed_at: 1.day.ago, valid_from: 1.day.ago, confidence: 1, retention_policy: :indefinite
    )
    expose_to(member, @memory)
    sign_in_as member.user

    get workspace_memory_records_path(@workspace)
    assert_response :success
    assert_select ".memory-record-list li", count: 1
    assert_select ".memory-record-list", text: /Accounts require an owner review/
    assert_select ".memory-record-list", text: /Hidden from unlinked members/, count: 0
    assert_equal "used", AuditEvent.where(action: "memory.library_inspected").last.metadata.fetch("access_scope")
    get workspace_memory_record_path(@workspace, hidden)
    assert_response :not_found

    sign_out
    viewer = @workspace.memberships.create!(user: users(:teammate), role: :viewer)
    sign_in_as viewer.user
    get workspace_memory_records_path(@workspace)
    assert_response :forbidden

    sign_out
    sign_in_as users(:owner)
    get workspace_memory_record_path(workspaces(:beta_support), @memory)
    assert_response :not_found
  end

  private
    def expose_to(member, memory)
      approve_scripted_runtime(workspace: @workspace, membership: @owner)
      CrewConfiguration.install_defaults!(workspace: @workspace)
      support_case = create_support_case
      profile = @workspace.agent_profiles.find_by!(role_key: "support_investigator")
      task = CrewWork.create!(
        workspace: @workspace, membership: member, scope: support_case, profile:,
        title: "Owned work", input_context: "Use memory.", expected_output: "Return findings."
      )
      @workspace.memory_index_entries.create!(
        memory_record: memory, status: :indexed, attempt_count: 1, external_document_id: "controller-document",
        external_status: "done", last_attempted_at: Time.current, indexed_at: Time.current
      )
      engine = Object.new
      engine.define_singleton_method(:search) do |query:|
        [ MemoryEngine::Hit.new(memory_key: memory.memory_key, score: 0.9) ]
      end
      ExecutionLedger.new(workspace: @workspace, memory_engine: engine)
        .prepare!(task:, request_key: "controller-member-memory")
    end
end
