require "test_helper"

class IntercomClientTest < ActiveSupport::TestCase
  setup do
    connection = workspaces(:acme_support).intercom_connections.create!(
      name: "Support Intercom", remote_workspace_id: "app_client", credential_key: "support"
    )
    connection.define_singleton_method(:access_token) { "token" }
    @client = IntercomClient.new(connection: connection)
    @requests = []
    requests = @requests
    @client.define_singleton_method(:perform) do |_uri, request|
      requests << request
      IntercomClient::Response.new(code: "200", body: '{"id":"remote_tag"}')
    end
  end

  test "attributes tag changes to the Intercom admin" do
    @client.tag(conversation_id: "conversation/1", tag_id: "tag_1", admin_id: "admin_1")
    @client.untag(conversation_id: "conversation/1", tag_id: "tag/1", admin_id: "admin_1")

    added, removed = @requests
    assert_equal "POST", added.method
    assert_equal "/conversations/conversation%2F1/tags", added.path
    assert_equal({ "id" => "tag_1", "admin_id" => "admin_1" }, JSON.parse(added.body))
    assert_equal "DELETE", removed.method
    assert_equal "/conversations/conversation%2F1/tags/tag%2F1", removed.path
    assert_equal({ "admin_id" => "admin_1" }, JSON.parse(removed.body))
    assert_equal IntercomClient::API_VERSION, removed["Intercom-Version"]
  end

  test "uses Intercom action values for notes and assignment" do
    @client.add_note(conversation_id: "conversation_1", admin_id: "admin_1", body: "Private note")
    @client.assign(conversation_id: "conversation_1", admin_id: "admin_1", assignee_id: "admin_2")

    note, assignment = @requests
    assert_equal "/conversations/conversation_1/reply", note.path
    assert_equal({
      "message_type" => "note", "type" => "admin", "admin_id" => "admin_1", "body" => "Private note"
    }, JSON.parse(note.body))
    assert_equal "/conversations/conversation_1/parts", assignment.path
    assert_equal({
      "message_type" => "assignment", "type" => "admin", "admin_id" => "admin_1", "assignee_id" => "admin_2"
    }, JSON.parse(assignment.body))
  end

  test "sends a customer-facing reply as the named Intercom admin" do
    @client.reply(conversation_id: "conversation_1", admin_id: "admin_1", body: "Human answer")

    reply = @requests.sole
    assert_equal "POST", reply.method
    assert_equal "/conversations/conversation_1/reply", reply.path
    assert_equal({
      "message_type" => "comment", "type" => "admin", "admin_id" => "admin_1", "body" => "Human answer"
    }, JSON.parse(reply.body))
  end

  test "lists teams with the pinned API version" do
    @client.teams

    request = @requests.sole
    assert_equal "GET", request.method
    assert_equal "/teams", request.path
    assert_equal IntercomClient::API_VERSION, request["Intercom-Version"]
  end
end
