class ScenariosController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: %i[index show]
  before_action :load_corpus
  rescue_from Scenario::Invalid, EvaluationHttp::Error, SupportOutput::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def index
    @page = params[:page].to_i.clamp(1, 10000)
    @scenarios = @corpus.scenarios.where(current_version: ScenarioVersion.unexpired).includes(:current_version).order(:id).offset((@page - 1) * 50).limit(51).to_a
    @more = @scenarios.size > 50
    @scenarios = @scenarios.first(50)
  end

  def create
    if params[:trace_item_id].present?
      item = @corpus.corpus_items.find(params[:trace_item_id])
      scenario = SupportTrace.propose!(item:, membership: Current.require_membership!)
      redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario), notice: "Trace candidate ready. Correct its expectations and company evidence before approval.", status: :see_other
    else
      analysis = @corpus.corpus_analyses.find(params[:analysis_id])
      ScenarioMining.call(analysis:, membership: Current.require_membership!)
      redirect_to workspace_corpus_scenarios_path(Current.workspace, @corpus), notice: "Candidates created. Historical answers are evidence, not approved expectations.", status: :see_other
    end
  rescue CorpusIntake::Invalid => error
    invalid_input(error)
  end

  def show
    @scenario = @corpus.scenarios.find(params[:id])
    @versions = @scenario.scenario_versions.order(number: :desc)
    @version = params[:version] ? @versions.find_by!(number: params[:version]) : @scenario.current_version
    raise ActiveRecord::RecordNotFound if @version.expired?
    @knowledge_items = @corpus.current_items.joins(source_snapshot: :source).where(sources: { kind: "document" }).order(:id).limit(100)
    @proposal = @version.scenario_proposal
    begin
      @proposal_input = ScenarioExtractor.input(@version) unless @proposal
    rescue Scenario::Invalid => error
      @proposal_input_error = error.message
    end
    @form_values ||= {}
  end

  def propose
    scenario = @corpus.scenarios.find(params[:id])
    version = scenario.scenario_versions.find(params[:version_id])
    raise Scenario::Invalid, "Model configuration must be JSON of at most 10 KiB." if params[:configuration].to_s.bytesize > 10.kilobytes
    ScenarioProposal.request!(version:, membership: Current.require_membership!, configuration: JSON.parse(params[:configuration].to_s), disclose: params[:proposal_disclose] == "1")
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario, version: version.number), notice: "Model proposal requested for this fixed version. Refresh never sends another request.", status: :see_other
  end

  def interrupt_proposal
    scenario = @corpus.scenarios.find(params[:id])
    version = scenario.scenario_versions.find(params[:version_id])
    version.scenario_proposal&.interrupt!(membership: Current.require_membership!)
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario, version: version.number), notice: "Proposal attempt interrupted. It will not retry automatically.", status: :see_other
  end

  def update
    scenario = @corpus.scenarios.find(params[:id])
    values = params.expect(scenario: [ :title, :situation, :taxonomy_label, :importance, :known_facts, :hidden_facts, *ScenarioVersion::REQUIREMENT_TYPES.map(&:to_sym) ]).to_h
    @form_values = values.dup
    values["known_facts"] = JSON.parse(values["known_facts"].to_s)
    values["hidden_facts"] = JSON.parse(values["hidden_facts"].to_s)
    values["requirements"] = ScenarioVersion::REQUIREMENT_TYPES.to_h { |kind| [ kind, values.delete(kind).to_s.lines.map(&:strip).reject(&:empty?) ] }
    previous_id = scenario.current_version_id
    version = scenario.revise!(membership: Current.require_membership!, base_version_id: params[:version_id], attributes: values,
      evidence_item_id: params[:evidence_item_id], excerpt: params[:excerpt], evidence_kind: params[:evidence_kind])
    message = version.id == previous_id ? "No changes. Kept the same version and review." : "Version saved. This version needs expert review."
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario), notice: message, status: :see_other
  end

  def review
    scenario = @corpus.scenarios.find(params[:id])
    scenario.review!(membership: Current.require_membership!, version_id: params[:version_id], decision: params[:decision], note: params[:note].to_s, merge_into_id: params[:merge_into_id])
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario), notice: "Expert decision saved for this version.", status: :see_other
  end

  def variant
    scenario = @corpus.scenarios.find(params[:id])
    child = scenario.variant!(membership: Current.require_membership!, version_id: params[:version_id], variable: params[:variable], after: JSON.parse(params[:after].to_s), reason: params[:reason], expected_difference: params[:expected_difference])
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, child), notice: "Controlled variant created. Correct its situation and expectations before approval.", status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end

    def invalid_input(error)
      message = if error.is_a?(JSON::ParserError)
        action_name == "propose" ? "Model configuration must be valid JSON. Correct it and request again." : "Facts and variant values must be valid JSON. Correct the value and save again."
      else
        error.message
      end
      if params[:id]
        show
        flash.now[:alert] = message
        render :show, status: :unprocessable_content
      else
        redirect_to workspace_corpus_scenarios_path(Current.workspace, @corpus), alert: message, status: :see_other
      end
    end
end
