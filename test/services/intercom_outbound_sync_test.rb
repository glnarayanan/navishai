require "test_helper"

class IntercomOutboundSyncTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(admins: [], unavailable: false)
      @admins = admins
      @unavailable = unavailable
      @calls = []
    end

    def admins
      { "admins" => @admins }
    end

    def add_note(**arguments)
      raise IntercomClient::Unavailable, "offline" if @unavailable

      @calls << [ :note, arguments ]
      { "id" => "part_note" }
    end

    def create_tag(name:)
      @calls << [ :create_tag, { name: name } ]
      { "id" => "remote_tag" }
    end

    def tag(**arguments)
      @calls << [ :tag, arguments ]
      { "id" => arguments.fetch(:tag_id) }
    end

    def untag(**arguments)
      @calls << [ :untag, arguments ]
      { "id" => arguments.fetch(:tag_id) }
    end

    def assign(**arguments)
      @calls << [ :assign, arguments ]
      { "id" => "assignment_1" }
    end
  end

  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @support_case = create_support_case
    @connection = @workspace.intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_123", credential_key: "support"
    )
    @link = @connection.intercom_conversation_links.create!(
      workspace: @workspace, conversation: @support_case.conversation, support_case: @support_case,
      remote_conversation_id: "conversation_1", remote_state: "open", source_digest: "a" * 64,
      remote_updated_at: Time.current, synced_at: Time.current
    )
    @client = FakeClient.new(admins: [ { "id" => "admin_1", "email" => @membership.user.email_address } ])
  end

  test "delivers a human-attributed private note once" do
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :note, payload: { body: "Check the account." }
    )

    result = IntercomOutboundSync.deliver!(operation, client: @client)
    replay = IntercomOutboundSync.deliver!(operation, client: @client)

    assert result.completed?
    assert_equal result, replay
    assert_equal 1, result.attempt_count
    assert_equal [ [ :note, {
      conversation_id: "conversation_1", admin_id: "admin_1", body: "Check the account."
    } ] ], @client.calls
    assert AuditEvent.where(action: "intercom.sync_completed", subject_id: operation.id, actor: @membership.user).exists?
  end

  test "leaves an uncertain write blocked for review" do
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :note, payload: { body: "Check the account." }
    )
    unavailable = FakeClient.new(
      admins: [ { "id" => "admin_1", "email" => @membership.user.email_address } ], unavailable: true
    )

    assert IntercomOutboundSync.deliver!(operation, client: unavailable).unknown?
    assert IntercomOutboundSync.deliver!(operation, client: @client).unknown?
    assert_empty @client.calls
    assert_equal "outcome_unknown", operation.reload.failure_code
  end

  test "creates and owns a remote tag before attaching it" do
    tag = @workspace.tags.create!(name: "VIP")
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :tag, payload: { tag_id: tag.id, name: tag.name }
    )

    assert IntercomOutboundSync.deliver!(operation, client: @client).completed?
    assert_equal "remote_tag", @connection.intercom_tag_links.find_by!(tag: tag).remote_tag_id
    assert_equal [ :create_tag, :tag ], @client.calls.map(&:first)
    assert_equal "admin_1", @client.calls.last.last.fetch(:admin_id)
  end

  test "locks the connection before creating a shared remote tag" do
    tag = @workspace.tags.create!(name: "Serialized")
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :tag, payload: { tag_id: tag.id, name: tag.name }
    )
    queries = []
    lock_seen_before_create = false
    client = @client
    client.define_singleton_method(:create_tag) do |name:|
      lock_seen_before_create = queries.any? do |sql|
        sql.include?("intercom_connections") && sql.include?("FOR UPDATE")
      end
      super(name:)
    end

    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last.fetch(:sql) }, "sql.active_record") do
      IntercomOutboundSync.deliver!(operation, client:)
    end

    assert lock_seen_before_create, "remote tag creation must hold the connection lock"
  end

  test "attributes a remote tag removal to the human actor" do
    tag = @workspace.tags.create!(name: "VIP")
    @connection.intercom_tag_links.create!(workspace: @workspace, tag: tag, remote_tag_id: "remote_tag")
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :untag, payload: { tag_id: tag.id, name: tag.name }
    )

    assert IntercomOutboundSync.deliver!(operation, client: @client).completed?
    assert_equal [ :untag, {
      conversation_id: "conversation_1", tag_id: "remote_tag", admin_id: "admin_1"
    } ], @client.calls.sole
  end

  test "retries only a definite failed write" do
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :note, payload: { body: "Check the account." }
    )
    no_admin = FakeClient.new(admins: [])
    assert IntercomOutboundSync.deliver!(operation, client: no_admin).failed?

    results = IntercomOutboundSync.retry!(connection: @connection, client: @client)

    assert_equal [ operation ], results
    assert operation.reload.completed?
    assert_equal 2, operation.attempt_count
    assert_equal 1, @client.calls.size
  end

  test "maps local assignment by exact Intercom admin email" do
    operation = IntercomOutboundSync.enqueue!(
      workspace: @workspace, support_case: @support_case, membership: @membership,
      operation_kind: :assign, payload: { email: @membership.user.email_address }
    )

    assert IntercomOutboundSync.deliver!(operation, client: @client).completed?
    assert_equal [ :assign, {
      conversation_id: "conversation_1", admin_id: "admin_1", assignee_id: "admin_1"
    } ], @client.calls.sole
  end
end
