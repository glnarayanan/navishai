class KnowledgeImprovementFollowUp
  STATES = %w[observed no_follow_up not_comparable].freeze

  Item = Data.define(
    :candidate, :state, :knowledge_version, :resolved_at, :artifact, :claim_states, :evidence_statuses
  ) do
    def observed? = state == "observed"
    def no_follow_up? = state == "no_follow_up"
    def not_comparable? = state == "not_comparable"
  end

  def self.build(workspace:, candidates:)
    new(workspace:, candidates:).build
  end

  def initialize(workspace:, candidates:)
    @workspace = workspace
    @candidates = candidates
  end

  def build
    comparable = @candidates.select { |candidate| candidate.support_case_id.present? && candidate.resolved_at.present? }
    artifacts_by_case = artifacts_for(comparable).group_by { |artifact| artifact.crew_task.support_case_id }

    @candidates.to_h do |candidate|
      [ candidate.id, item_for(candidate, artifacts_by_case.fetch(candidate.support_case_id, [])) ]
    end
  end

  private
    def artifacts_for(candidates)
      return [] if candidates.empty?

      @workspace.crew_artifacts.joins(:crew_task).includes(:crew_task).where(
        crew_tasks: { support_case_id: candidates.map(&:support_case_id).uniq }
      ).where("crew_artifacts.created_at > ?", candidates.map(&:resolved_at).min).order(created_at: :desc, id: :desc)
    end

    def item_for(candidate, artifacts)
      version = candidate.resolved_knowledge_source_version
      return Item.new(candidate:, state: "not_comparable", knowledge_version: version, resolved_at: candidate.resolved_at,
        artifact: nil, claim_states: [], evidence_statuses: []) unless candidate.support_case_id && version

      artifact, claims = artifacts.lazy.filter_map do |record|
        next unless record.created_at > candidate.resolved_at

        matches = linked_claims(record, version.citation_uri)
        [ record, matches ] if matches.any?
      end.first || [ nil, [] ]
      states = claims.map { |claim| claim.fetch("state", "uncertain") }.uniq
      statuses = claims.flat_map { |claim| claim.fetch("evidence", []) }
        .select { |evidence| evidence["kind"] == "knowledge" && evidence["locator"] == version.citation_uri }
        .filter_map { |evidence| evidence["status"] }.uniq
      Item.new(
        candidate:, state: artifact ? "observed" : "no_follow_up", knowledge_version: version,
        resolved_at: candidate.resolved_at, artifact:, claim_states: states, evidence_statuses: statuses
      )
    end

    def linked_claims(artifact, locator)
      artifact.material_claims.select do |claim|
        claim.fetch("evidence", []).any? do |evidence|
          evidence["kind"] == "knowledge" && evidence["locator"] == locator
        end
      end
    end
end
