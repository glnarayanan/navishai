class ScenariosController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: %i[index show]
  before_action :load_corpus
  rescue_from Scenario::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def index
    @page = params[:page].to_i.clamp(1, 10000)
    @scenarios = @corpus.scenarios.where(current_version: ScenarioVersion.unexpired).includes(:current_version).order(:id).offset((@page - 1) * 50).limit(51).to_a
    @more = @scenarios.size > 50
    @scenarios = @scenarios.first(50)
  end

  def create
    analysis = @corpus.corpus_analyses.find(params[:analysis_id])
    ScenarioMining.call(analysis:, membership: Current.require_membership!)
    redirect_to workspace_corpus_scenarios_path(Current.workspace, @corpus), notice: "Candidates created. Historical answers are evidence, not approved expectations.", status: :see_other
  end

  def show
    @scenario = @corpus.scenarios.find(params[:id])
    @versions = @scenario.scenario_versions.order(number: :desc)
    @version = params[:version] ? @versions.find_by!(number: params[:version]) : @scenario.current_version
    raise ActiveRecord::RecordNotFound if @version.expired?
    @knowledge_items = @corpus.current_items.joins(source_snapshot: :source).where(sources: { kind: "document" }).order(:id).limit(100)
    @form_values ||= {}
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
      message = error.is_a?(JSON::ParserError) ? "Facts and variant values must be valid JSON. Correct the value and save again." : error.message
      if params[:id]
        show
        flash.now[:alert] = message
        render :show, status: :unprocessable_content
      else
        redirect_to workspace_corpus_scenarios_path(Current.workspace, @corpus), alert: message, status: :see_other
      end
    end
end
