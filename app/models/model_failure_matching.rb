class ModelFailureMatching < ApplicationRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :corpus_item
  belongs_to :requested_by, class_name: "User"
  has_many :model_failure_matching_candidates
  has_one :model_failure_matching_result
  self.filter_attributes += [ :input ]
  attr_readonly :workspace_id, :corpus_id, :corpus_item_id, :requested_by_id, :configuration, :input, :input_digest, :processing_version, :request_key, :created_at
  validates :state, inclusion: { in: %w[queued running complete interrupted] }

  def self.request!(item:, membership:, configuration:, input_digest:, request_digest:, disclose: false, endpoint_confirmation: nil)
    item.corpus.with_lock do
      item.corpus.authorize_writer!(membership)
      raise Scenario::Invalid, "Use endpoint, model and fixed settings only. Credentials belong in the operator registry." unless ModelGateway.valid_configuration?(configuration)
      raise Scenario::Invalid, "Confirm the exact matching endpoint, purpose and complete contents before requesting suggestions." unless
        disclose == true && endpoint_confirmation == configuration.fetch("endpoint")
      input = ModelFailureMatcher.input(item)
      raise Scenario::Invalid, "Matching preview changed. Preview the current eligible versions and confirm disclosure again; no request started." unless ModelFailureMatcher.digest(input) == input_digest
      raise Scenario::Invalid, "Matching endpoint or settings changed. Preview the exact request and confirm again; no request started." unless ModelFailureMatcher.request_digest(input, configuration) == request_digest
      EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id: item.workspace_id, purpose: :matching)
      existing = find_by(corpus_item: item, input_digest:, configuration:)
      return existing if existing
      request = create!(workspace: item.workspace, corpus: item.corpus, corpus_item: item, requested_by: membership.user,
        configuration:, input:, input_digest:, processing_version: ModelFailureMatcher::VERSION, created_at: Time.current)
      input.fetch("candidates").each do |candidate|
        request.model_failure_matching_candidates.create!(workspace: item.workspace, corpus: item.corpus, scenario_version_id: candidate.fetch("scenario_version_id"))
      end
      AuditEvent.record!(action: "trace.matching_requested", source: :web, workspace: item.workspace, actor: membership.user, subject: request)
      ModelFailureMatchingJob.perform_later(request.id)
      request
    end
  end

  def authorize_execution!
    reload
    return false unless state == "running"
    raise Scenario::Invalid, "Unsupported matching protocol or settings." unless processing_version == ModelFailureMatcher::VERSION && ModelGateway.valid_configuration?(configuration)
    corpus.authorize_writer!(workspace.memberships.find_by!(user: requested_by))
    current = ModelFailureMatcher.input(corpus_item)
    raise Scenario::Invalid, "Fixed matching preview changed." unless ModelFailureMatcher.digest(current) == input_digest && current.eql?(input)
    EvaluationHttp.validate!(configuration.slice("endpoint"), workspace_id:, purpose: :matching)
    true
  end

  def interrupt!(membership:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      lock!
      raise Scenario::Invalid, "Only queued work or an attempt started over ten minutes ago can be stopped." unless state == "queued" || (state == "running" && started_at < 10.minutes.ago)
      update!(state: "interrupted", finished_at: Time.current, error: "Expert stopped this attempt. Its remote outcome/cost may be unknown; it will not retry.")
      AuditEvent.record!(action: "trace.matching_interrupted", source: :web, workspace:, actor: membership.user, subject: self)
    end
  end
end
