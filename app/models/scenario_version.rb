class ScenarioVersion < ImmutableRecord
  EDITABLE = %w[title situation taxonomy_label importance known_facts hidden_facts requirements].freeze
  REQUIREMENT_TYPES = %w[outcomes actions forbidden escalation grounding].freeze
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :scenario
  belongs_to :created_by, class_name: "User"
  has_many :scenario_evidence, class_name: "ScenarioEvidence"
  has_many :scenario_reviews
  has_many :eval_cases
  scope :unexpired, -> { where.not(id: ScenarioEvidence.joins(corpus_item: { source_snapshot: :source }).where("sources.expires_at <= ?", Time.current).select(:scenario_version_id)) }
  validates :title, :situation, :taxonomy_label, :selection_reason, presence: true
  validates :title, :taxonomy_label, length: { maximum: 500 }
  validates :situation, :selection_reason, length: { maximum: 10_000 }
  validates :importance, inclusion: { in: %w[normal high critical] }
  validates :origin, inclusion: { in: %w[mined expert variant] }
  validates :number, numericality: { only_integer: true, greater_than: 0 }
  validate :structured_definition

  def latest_review
    scenario_reviews.order(id: :desc).first
  end

  def approved?
    latest_review&.decision == "approve" && scenario.merged_into_id.nil?
  end

  def stale?
    scenario_evidence.joins(corpus_item: { source_snapshot: :source }).where(sources: { kind: "document" }).where("sources.current_snapshot_id <> source_snapshots.id").exists?
  end

  def expired?
    scenario_evidence.joins(corpus_item: { source_snapshot: :source }).where("sources.expires_at <= ?", Time.current).exists?
  end

  def target_input
    { "situation" => situation, "known_facts" => known_facts,
      "knowledge" => scenario_evidence.where(kind: "knowledge").order(:id).map { |evidence| { "reference" => "corpus-item-#{evidence.corpus_item_id}", "content" => evidence.excerpt } } }
  end

  private
    def structured_definition
      [ known_facts, hidden_facts, mutation ].each do |value|
        errors.add(:base, "Facts and mutation must be JSON objects of at most 10 KiB.") unless value.is_a?(Hash) && value.to_json.bytesize <= 10.kilobytes && !value.to_json.include?("\\u0000")
      end
      valid = requirements.is_a?(Hash) && (requirements.keys - REQUIREMENT_TYPES).empty? &&
        REQUIREMENT_TYPES.all? { |kind| requirements[kind].is_a?(Array) && requirements[kind].size <= 20 && requirements[kind].all? { |text| text.is_a?(String) && text.strip.length.between?(1, 2000) && !text.include?("\0") } }
      errors.add(:requirements, "need outcomes, actions, forbidden, escalation and grounding arrays of short statements") unless valid
      errors.add(:base, "Text cannot contain null bytes.") if [ title, situation, taxonomy_label, selection_reason ].any? { |text| text.to_s.include?("\0") }
    end
end
