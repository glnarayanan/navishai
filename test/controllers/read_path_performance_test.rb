require "test_helper"

class ReadPathPerformanceTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    sign_in_as users(:owner)
  end

  test "case queue and detail keep record lookups bounded" do
    support_case = nil
    25.times do |index|
      account = @workspace.accounts.create!(name: "Queue account #{index}")
      contact = @workspace.contacts.create!(account:, name: "Queue contact #{index}")
      support_case = create_support_case(subject: "Queue case #{index}", contact:)
      add_inbound_message(support_case, body: "Queue message #{index}")
    end
    now = Time.current
    user_rows = 12.times.map do |index|
      {
        email_address: "read-path-author-#{index}@example.com",
        password_digest: users(:owner).password_digest,
        verified_at: now,
        created_at: now,
        updated_at: now
      }
    end
    user_ids = User.insert_all!(user_rows, returning: %w[id]).rows.flatten
    Membership.insert_all!(user_ids.map do |user_id|
      { workspace_id: @workspace.id, user_id:, role: "member", created_at: now, updated_at: now }
    end)
    ConversationMessage.insert_all!(user_ids.each_with_index.map do |user_id, index|
      {
        workspace_id: @workspace.id,
        conversation_id: support_case.conversation_id,
        direction: "outbound",
        author_kind: "user",
        author_user_id: user_id,
        body: "Author message #{index}",
        occurred_at: now + index.seconds,
        created_at: now,
        updated_at: now
      }
    end)

    queue_queries = capture_sql { get workspace_support_cases_path(@workspace) }
    assert_response :success
    assert_operator table_query_count(queue_queries, "contact_merges"), :<=, 1
    assert_operator table_query_count(queue_queries, "account_merges"), :<=, 1

    detail_queries = capture_sql { get workspace_support_case_path(@workspace, support_case) }
    assert_response :success
    assert_operator table_query_count(detail_queries, "users"), :<=, 6
  end

  test "memory library preloads case scope labels" do
    25.times do |index|
      support_case = create_support_case(subject: "Memory case #{index}")
      add_inbound_message(support_case, body: "Memory message #{index}")
    end

    queries = capture_sql { get workspace_memory_records_path(@workspace) }

    assert_response :success
    assert_operator table_query_count(queries, "support_cases"), :<=, 1
    assert_operator table_query_count(queries, "conversations"), :<=, 1
  end

  private
    def capture_sql
      queries = []
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      queries
    end

    def table_query_count(queries, table)
      queries.count { |sql| sql.match?(/\bFROM "#{Regexp.escape(table)}"\b/) }
    end
end
