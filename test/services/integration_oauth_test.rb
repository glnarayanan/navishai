require "test_helper"

class IntegrationOauthTest < ActiveSupport::TestCase
  setup do
    @keys = %w[CLIENT_ID CLIENT_SECRET REDIRECT_URI].map { |key| "NAVISHAI_NOTION_OAUTH_#{key}" }
    @previous = @keys.to_h { |key| [ key, ENV[key] ] }
    ENV[@keys[0]] = "client-id"
    ENV[@keys[1]] = "client-secret"
    ENV[@keys[2]] = "https://navishai.example/oauth/notion/callback"
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "authorization uses fixed provider host and configured callback" do
    url = URI(IntegrationOauth.new("notion").authorization_url(state: "state-value"))
    assert_equal "api.notion.com", url.host
    assert_equal "https://navishai.example/oauth/notion/callback", URI.decode_www_form(url.query).to_h.fetch("redirect_uri")
    assert_equal "user", URI.decode_www_form(url.query).to_h.fetch("owner")
  end

  test "missing configuration and insecure callbacks fail closed" do
    ENV[@keys[2]] = "http://navishai.example/oauth/notion/callback"
    assert_not IntegrationOauth.new("notion").configured?
    ENV.delete(@keys[0])
    assert_raises(IntegrationOauth::Unavailable) { IntegrationOauth.new("notion").authorization_url(state: "state-value") }
  end

  test "token exchange rejects bot ownership rather than sharing it as a personal account" do
    oauth = IntegrationOauth.new("notion")
    oauth.define_singleton_method(:perform) { |*_arguments| { "access_token" => "token", "workspace_id" => "workspace", "owner" => { "workspace" => true } } }
    assert_raises(IntegrationOauth::Unavailable) { oauth.exchange(code: "code") }
  end

  test "Notion exchange binds user and workspace without returning provider payloads" do
    oauth = IntegrationOauth.new("notion")
    oauth.define_singleton_method(:perform) do |uri, request|
      raise "wrong destination" unless uri.to_s == "https://api.notion.com/v1/oauth/token"
      raise "missing authentication" unless request["Authorization"].start_with?("Basic ")

      { "access_token" => "token", "workspace_id" => "workspace", "owner" => { "user" => { "id" => "user" } }, "extra" => "omit" }
    end
    assert_equal({ access_token: "token", remote_user_id: "user", remote_workspace_id: "workspace", refresh_token: nil, expires_at: nil }, oauth.exchange(code: "code"))
  end
end

class IntegrationPersonalContentTest < ActiveSupport::TestCase
  test "Notion reads only a bounded page list with the personal token" do
    oauth = IntegrationOauth.new("notion")
    oauth.define_singleton_method(:perform) do |uri, request|
      raise "wrong endpoint" unless uri.to_s == "https://api.notion.com/v1/search"
      raise "wrong token" unless request["Authorization"] == "Bearer personal-token"
      raise "unbounded request" unless JSON.parse(request.body)["page_size"] == 20
      { "results" => [ { "id" => "page-id", "properties" => { "Name" => { "type" => "title", "title" => [ { "plain_text" => "Private handbook" } ] } } } ] }
    end
    assert_equal [ { id: "page-id", title: "Private handbook" } ], oauth.personal_content(token: "personal-token")
  end

  test "Intercom reads conversation titles without customer messages" do
    oauth = IntegrationOauth.new("intercom")
    oauth.define_singleton_method(:perform) do |uri, request|
      raise "wrong endpoint" unless uri.to_s == "https://api.intercom.io/conversations?per_page=20"
      raise "wrong token" unless request["Authorization"] == "Bearer personal-token"
      { "conversations" => [ { "id" => "42", "title" => "Delivery", "source" => { "body" => "Not returned" } } ] }
    end
    assert_equal [ { id: "42", title: "Delivery" } ], oauth.personal_content(token: "personal-token")
  end

  test "oversized provider results are rejected" do
    oauth = IntegrationOauth.new("notion")
    oauth.define_singleton_method(:perform) { |*_arguments| { "results" => Array.new(21, {}) } }
    assert_raises(IntegrationOauth::Unavailable) { oauth.personal_content(token: "personal-token") }
  end
end
