class Scenario < ApplicationRecord
  class Invalid < StandardError; end
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_item
  belongs_to :cluster_member, optional: true
  belongs_to :parent_version, class_name: "ScenarioVersion", optional: true
  belongs_to :current_version, class_name: "ScenarioVersion", optional: true
  belongs_to :merged_into, class_name: "Scenario", optional: true
  has_many :scenario_versions

  def revise!(membership:, base_version_id:, attributes:, evidence_item_id: nil, excerpt: nil, evidence_kind: nil, conversation_excerpt: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      reload
      raise Invalid, "This scenario changed. Reload before saving." unless current_version_id.to_s == base_version_id.to_s
      raise Invalid, "Merged scenarios cannot be edited." if merged_into_id
      raise Invalid, "Source evidence expired." if current_version.expired?
      previous = current_version
      values = previous.attributes.slice(*ScenarioVersion::EDITABLE).merge(attributes.stringify_keys.slice(*ScenarioVersion::EDITABLE))
      raise Invalid, "Conversation excerpt must be text." unless conversation_excerpt.nil? || conversation_excerpt.is_a?(String)
      conversation = previous.scenario_evidence.joins(corpus_item: { source_snapshot: :source }).find_by(corpus_item_id:, kind: "expectation", sources: { kind: "conversations" }) if conversation_excerpt.present?
      raise Invalid, "This version has no linked historical conversation excerpt to replace." if conversation_excerpt.present? && !conversation
      conversation_changed = conversation && conversation.excerpt != conversation_excerpt
      item = corpus.evidence_items.find(evidence_item_id) if evidence_item_id.present?
      raise Invalid, "This record already supports the version with that evidence kind." if item && previous.scenario_evidence.exists?(corpus_item: item, kind: evidence_kind)
      return previous if !item && !conversation_changed && values.eql?(previous.attributes.slice(*ScenarioVersion::EDITABLE))

      version = scenario_versions.create!(values.merge(workspace:, corpus:, created_by: membership.user,
        number: previous.number + 1, origin: "expert", selection_reason: previous.selection_reason,
        mutation: previous.mutation, draft_notes: previous.draft_notes, created_at: Time.current))
      previous.scenario_evidence.each do |evidence|
        next if conversation_changed && evidence.id == conversation.id
        next if item && item.source_snapshot.source.kind == "document" && evidence.kind == evidence_kind && evidence.corpus_item.source_snapshot.source_id == item.source_snapshot.source_id

        version.scenario_evidence.create!(workspace:, corpus:, corpus_item: evidence.corpus_item, kind: evidence.kind, excerpt: evidence.excerpt)
      end
      version.scenario_evidence.create!(workspace:, corpus:, corpus_item: conversation.corpus_item, kind: "expectation", excerpt: conversation_excerpt) if conversation_changed
      version.scenario_evidence.create!(workspace:, corpus:, corpus_item: item, kind: evidence_kind, excerpt:) if item
      update!(current_version: version)
      audit!("scenario.revised", membership, version)
      version
    end
  end

  def review!(membership:, version_id:, decision:, note: "", merge_into_id: nil)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      reload
      raise Invalid, "This scenario changed. Reload before reviewing." unless current_version_id.to_s == version_id.to_s
      version = current_version
      raise Invalid, "Merged scenarios cannot be reviewed." if merged_into_id
      raise Invalid, "Source evidence expired." if version.expired?
      raise Invalid, "Review and revise the variant's starting situation and expectations before approval." if decision == "approve" && version.origin == "variant"
      if decision == "approve" && (version.requirements["outcomes"].empty? || !version.scenario_evidence.where(kind: "expectation").exists?)
        raise Invalid, "Set a source-backed expected outcome before approval."
      end
      raise Invalid, "Enter the ID of an approved scenario to merge into." if decision == "merge" && merge_into_id.blank?
      target = corpus.scenarios.find(merge_into_id) if decision == "merge"
      raise Invalid, "Merge into a different approved, active scenario." if target && (target == self || !target.current_version.approved? || target.current_version.expired?)
      review = version.scenario_reviews.create!(workspace:, corpus:, reviewed_by: membership.user,
        decision:, note:, merged_version: target&.current_version, created_at: Time.current)
      update!(merged_into: target) if target
      audit!("scenario.reviewed", membership, version)
      review
    end
  end

  def variant!(membership:, version_id:, variable:, after:, reason:, expected_difference:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      reload
      parent = current_version
      raise Invalid, "Create a variant from the current approved version." unless parent.id.to_s == version_id.to_s && parent.approved? && !parent.expired?
      raise Invalid, "Choose one existing fact and a different JSON value." unless parent.known_facts.key?(variable) && !parent.known_facts[variable].eql?(after)
      raise Invalid, "Explain the mutation and its expected behaviour change (1–2000 characters each)." unless [ reason, expected_difference ].all? { |text| text.is_a?(String) && text.strip.length.between?(1, 2000) }
      child = corpus.scenarios.create!(workspace:, corpus_item:, parent_version: parent)
      values = parent.attributes.slice(*ScenarioVersion::EDITABLE)
      values["known_facts"] = parent.known_facts.merge(variable => after)
      version = child.scenario_versions.create!(values.merge(workspace:, corpus:, created_by: membership.user,
        number: 1, origin: "variant", selection_reason: "Controlled variant of scenario #{id}, version #{parent.number}",
        mutation: { "variable" => variable, "before" => parent.known_facts[variable], "after" => after, "reason" => reason, "expected_difference" => expected_difference }, created_at: Time.current))
      parent.scenario_evidence.each { |evidence| version.scenario_evidence.create!(workspace:, corpus:, corpus_item: evidence.corpus_item, kind: evidence.kind, excerpt: evidence.excerpt) }
      child.update!(current_version: version)
      audit!("scenario.variant_created", membership, version)
      child
    end
  end

  private
    def audit!(action, membership, version)
      AuditEvent.record!(action:, source: :web, workspace:, actor: membership.user, subject: version, metadata: { version: version.number })
    end
end
