require "test_helper"

class NotionKnowledgeClientTest < ActiveSupport::TestCase
  ROOT = "11111111-1111-1111-1111-111111111111"
  DATABASE = "22222222-2222-2222-2222-222222222222"
  SOURCE = "33333333-3333-3333-3333-333333333333"
  CHILD = "44444444-4444-4444-4444-444444444444"

  test "rendering traverses data sources and labels unsupported content" do
    responses = {
      [ :get, "/v1/pages/#{ROOT}" ] => { "id" => ROOT },
      [ :get, "/v1/blocks/#{ROOT}/children" ] => list([
        { "type" => "paragraph", "paragraph" => { "rich_text" => [ { "plain_text" => "Recovery steps" } ] } },
        { "type" => "image", "image" => {} },
        { "id" => DATABASE, "type" => "child_database", "child_database" => { "title" => "Procedures" } }
      ]),
      [ :get, "/v1/databases/#{DATABASE}" ] => { "data_sources" => [ { "id" => SOURCE } ] },
      [ :post, "/v1/data_sources/#{SOURCE}/query" ] => list([ { "id" => CHILD } ])
    }
    client = fixture_client(responses)
    document = client.document(ROOT)
    assert_includes document[:text], "Recovery steps"
    assert_includes document[:text], "Content omitted: unsupported Notion block image"
    assert_equal [ CHILD ], document[:children]
  end

  test "repeated cursors fail instead of looping" do
    responses = {
      [ :get, "/v1/pages/#{ROOT}" ] => { "id" => ROOT },
      [ :get, "/v1/blocks/#{ROOT}/children" ] => { "results" => [], "has_more" => true, "next_cursor" => "same" }
    }
    error = assert_raises(NotionKnowledgeClient::Error) { fixture_client(responses).document(ROOT) }
    assert_equal "notion_invalid_cursor", error.message
  end

  test "archived pages do not read blocks" do
    client = fixture_client({ [ :get, "/v1/pages/#{ROOT}" ] => { "id" => ROOT, "archived" => true } })
    assert_equal [], client.document(ROOT)[:children]
  end

  test "nested missing database is incomplete while missing page metadata remains absent" do
    client = NotionKnowledgeClient.new(connection: nil)
    client.define_singleton_method(:request) do |_method, path, **_options|
      case path
      when "/v1/pages/#{ROOT}" then { "id" => ROOT }
      when "/v1/blocks/#{ROOT}/children"
        { "results" => [ { "id" => DATABASE, "type" => "child_database", "child_database" => { "title" => "Private" } } ], "has_more" => false }
      else raise NotionKnowledgeClient::Missing, "notion_missing"
      end
    end
    error = assert_raises(NotionKnowledgeClient::Error) { client.document(ROOT) }
    assert_not error.is_a?(NotionKnowledgeClient::Missing)
    assert_equal "notion_incomplete_document", error.message
    assert_raises(NotionKnowledgeClient::Missing) { client.document(CHILD) }
  end

  private
    def list(results)
      { "results" => results, "has_more" => false }
    end

    def fixture_client(responses)
      client = NotionKnowledgeClient.new(connection: nil)
      client.define_singleton_method(:request) { |method, path, **_options| responses.fetch([ method, path ]) }
      client
    end
end
