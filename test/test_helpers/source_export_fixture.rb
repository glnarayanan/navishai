module SourceExportFixture
  def export_snapshot(corpus:, membership:, name: "Retained support", marker: "historical", count: 61)
    records = count.times.map do |index|
      { id: "#{marker}-#{index}", title: "#{marker} café #{index}", content: "#{marker} \"quoted\"\n\\ path 雪 person@example.org",
        context: { nested: [ { "person@example.org" => "person@example.org", "facts" => [ false, nil, 0, "雪" ] } ] } }
    end
    CorpusIntake.call(corpus:, membership:, name:, kind: "conversations", bytes: JSON.generate(records))
  end
end
