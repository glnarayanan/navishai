require "test_helper"
require_relative "../test_helpers/zip_fixture_helper"

class KnowledgeZipBundleTest < ActiveSupport::TestCase
  include ZipFixtureHelper

  test "reads stored and deflated documents and skips directories" do
    archive = build_zip([
      { name: "playbooks/", data: "" },
      { name: "playbooks/reset.md", data: "# Reset\n\nLinks expire." },
      { name: "faq.txt", data: "Plain answer", method: 0 },
      { name: "guide.pdf", data: file_fixture("guide.pdf").binread }
    ])

    assert KnowledgeZipBundle.bundle?(archive)
    entries = KnowledgeZipBundle.entries(archive)
    assert_equal %w[playbooks/reset.md faq.txt guide.pdf], entries.map(&:filename)
    assert_equal "# Reset\n\nLinks expire.", entries[0].data
    assert_equal "Plain answer", entries[1].data
    assert_equal file_fixture("guide.pdf").binread, entries[2].data
  end

  test "refuses traversal, absolute paths, symlinks, unsupported files, and nested archives" do
    {
      "traversal" => [ { name: "../etc/passwd.txt", data: "x" } ],
      "absolute" => [ { name: "/etc/motd.txt", data: "x" } ],
      "symlink" => [ { name: "link.txt", data: "target", symlink: true } ],
      "unsupported" => [ { name: "script.js", data: "alert(1)" } ],
      "nested" => [ { name: "inner.zip", data: "PK\x03\x04".b } ],
      "empty" => [ { name: "only/", data: "" } ]
    }.each do |label, entries|
      error = assert_raises(KnowledgeZipBundle::InvalidBundle, label) { KnowledgeZipBundle.entries(build_zip(entries)) }
      assert error.message.present?, label
    end
  end

  test "refuses size lies, corrupt data, and too many entries" do
    lie = build_zip([ { name: "lie.txt", data: "short", declared_size: 4_000 } ])
    assert_raises(KnowledgeZipBundle::InvalidBundle) { KnowledgeZipBundle.entries(lie) }

    corrupt = build_zip([ { name: "corrupt.txt", data: Random.new(1).bytes(400) } ])
    corrupt[corrupt.index("PK\x01\x02".b) - 20, 8] = ("\xFF" * 8).b
    assert_raises(KnowledgeZipBundle::InvalidBundle) { KnowledgeZipBundle.entries(corrupt) }

    many = build_zip((1..51).map { |index| { name: "note-#{index}.txt", data: "n" } })
    assert_raises(KnowledgeZipBundle::InvalidBundle) { KnowledgeZipBundle.entries(many) }

    assert_raises(KnowledgeZipBundle::InvalidBundle) { KnowledgeZipBundle.entries("not a zip") }
    assert_raises(KnowledgeZipBundle::InvalidBundle) { KnowledgeZipBundle.entries("PK\x03\x04truncated".b) }
  end
end
