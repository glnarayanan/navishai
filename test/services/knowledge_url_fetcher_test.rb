require "test_helper"

class KnowledgeUrlFetcherTest < ActiveSupport::TestCase
  Resolver = Struct.new(:addresses) do
    def getaddresses(host)
      addresses.fetch(host, [])
    end
  end

  test "fetches bounded HTML through pinned public addresses and revalidates redirects" do
    requests = []
    responses = {
      "docs.example.com" => response(status: 302, location: "https://help.example.org/article"),
      "help.example.org" => response(
        body: "<html><body><main>Reset <strong>access</strong>.</main><script>steal()</script></body></html>",
        content_type: "text/html; charset=utf-8", last_modified: "Wed, 20 Aug 2026 10:00:00 GMT"
      )
    }
    requester = lambda do |uri, address|
      requests << [ uri.host, address ]
      responses.fetch(uri.host)
    end
    fetcher = KnowledgeUrlFetcher.new(
      resolver: Resolver.new({
        "docs.example.com" => [ "93.184.216.34" ],
        "help.example.org" => [ "142.250.72.132" ]
      }),
      requester:
    )
    now = Time.zone.parse("2026-08-24 12:00 UTC")

    result = fetcher.fetch("https://DOCS.example.com.:443/start#section", now:)

    assert_equal "Reset access.", result.content
    assert_equal "https://help.example.org/article", result.url
    assert_equal now, result.retrieved_at
    assert_equal Time.zone.parse("2026-08-20 10:00 UTC"), result.source_updated_at
    assert_equal [ [ "docs.example.com", "93.184.216.34" ], [ "help.example.org", "142.250.72.132" ] ], requests
  end

  test "rejects private, mixed, redirected, oversized, and unsupported sources" do
    requester = ->(*) { flunk "private addresses must fail before a request" }
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeUrlFetcher.new(resolver: Resolver.new({}), requester:).fetch("https://127.0.0.1/article")
    end
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeUrlFetcher.new(resolver: Resolver.new({}), requester:).fetch("https://metadata.internal/article")
    end
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeUrlFetcher.new(
        resolver: Resolver.new({ "private.example" => [ "10.0.0.4" ] }), requester:
      ).fetch("https://private.example/article")
    end
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeUrlFetcher.new(
        resolver: Resolver.new({ "mixed.example" => [ "93.184.216.34", "127.0.0.1" ] }), requester:
      ).fetch("https://mixed.example/article")
    end

    redirect_fetcher = KnowledgeUrlFetcher.new(
      resolver: Resolver.new({
        "public.example" => [ "93.184.216.34" ], "internal.example" => [ "192.168.1.2" ]
      }),
      requester: ->(*) { response(status: 302, location: "https://internal.example/secret") }
    )
    assert_raises(KnowledgeIngestion::InvalidSource) { redirect_fetcher.fetch("https://public.example") }

    public_resolver = Resolver.new({ "public.example" => [ "93.184.216.34" ] })
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeUrlFetcher.new(
        resolver: public_resolver,
        requester: ->(*) { response(body: "x", content_type: "application/pdf") }
      ).fetch("https://public.example")
    end
    assert_raises(KnowledgeIngestion::InvalidSource) do
      KnowledgeUrlFetcher.new(
        resolver: public_resolver,
        requester: ->(*) { response(body: "x" * (KnowledgeUrlFetcher::MAX_BYTES + 1)) }
      ).fetch("https://public.example")
    end
  end

  test "URL ingestion uses a secure fetch result when reviewed text is absent" do
    fetched_at = Time.zone.parse("2026-08-24 12:00 UTC")
    updated_at = Time.zone.parse("2026-08-23 09:00 UTC")
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url|
      raise "wrong URL" unless url == "https://docs.example.com/start"

      KnowledgeUrlFetcher::Result.new(
        content: "Fetched recovery guidance", url: "https://docs.example.com/final",
        retrieved_at: fetched_at, source_updated_at: updated_at
      )
    end

    source = KnowledgeIngestion.create!(
      workspace: workspaces(:acme_support), membership: memberships(:owner_support),
      source_kind: :url, title: "Fetched guide", url: "https://docs.example.com/start",
      url_fetcher: fetcher
    )

    assert_equal "https://docs.example.com/start", source.canonical_url
    assert_equal "https://docs.example.com/final", source.current_version.retrieved_from_url
    assert_equal "Fetched recovery guidance", source.current_version.content
    assert_equal fetched_at, source.current_version.retrieved_at
    assert_equal updated_at, source.current_version.source_updated_at
  end

  private
    def response(status: 200, location: nil, content_type: "text/plain", content_length: nil, body: "ok", last_modified: nil)
      KnowledgeUrlFetcher::Response.new(
        status:, location:, content_type:, content_length: content_length || body.bytesize,
        body:, last_modified:
      )
    end
end
