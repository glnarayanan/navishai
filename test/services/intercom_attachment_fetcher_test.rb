require "test_helper"

class IntercomAttachmentFetcherTest < ActiveSupport::TestCase
  Resolver = Struct.new(:addresses) do
    def getaddresses(_host) = addresses
  end

  test "fetches a bounded attachment with GET-only public address validation" do
    requests = []
    fetcher = IntercomAttachmentFetcher.new(
      resolver: Resolver.new([ "93.184.216.34" ]),
      requester: ->(uri, address) {
        requests << [ uri.to_s, address ]
        { status: 200, location: nil, body: "attachment".b }
      }
    )

    assert_equal "attachment", fetcher.fetch("https://files.example.com/history.txt")
    assert_equal [ [ "https://files.example.com/history.txt", "93.184.216.34" ] ], requests
  end

  test "rejects local addresses and unsafe URLs before transport" do
    fetcher = IntercomAttachmentFetcher.new(
      resolver: Resolver.new([ "127.0.0.1" ]), requester: ->(*) { flunk "transport must not run" }
    )

    assert_raises(IntercomAttachmentFetcher::Error) { fetcher.fetch("https://files.example.com/history.txt") }
    assert_raises(IntercomAttachmentFetcher::Error) { fetcher.fetch("http://files.example.com/history.txt") }
  end
end
