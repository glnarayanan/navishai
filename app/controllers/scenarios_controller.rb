class ScenariosController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: %i[index show]
  before_action :load_corpus
  rescue_from Scenario::Invalid, EvaluationHttp::Error, SupportOutput::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def index
    @query = params[:corpus_query].to_s
    query = @query.strip
    @corpus.with_lock do
      versions = ScenarioVersion.where(corpus: @corpus).unexpired
      if query.length > 200 || query.include?("\0")
        @search_error = "Search needs at most 200 characters and no null bytes. Shorten the phrase and try again."
        versions = versions.none
      elsif query.present?
        pattern = ActiveRecord::Relation::QueryAttribute.new("corpus_query",
          "%#{ActiveRecord::Base.sanitize_sql_like(query)}%", ScenarioVersion.type_for_attribute("title"))
        versions = versions.where("scenario_versions.title ILIKE :pattern OR scenario_versions.situation ILIKE :pattern OR scenario_versions.taxonomy_label ILIKE :pattern", pattern:)
      end
      matching = @corpus.scenarios.where(current_version: versions)
      @matching_count = matching.count
      @page = params[:page].to_i.clamp(1, 10000)
      @more = @matching_count > @page * 50
      @scenarios = matching.order(:id).offset((@page - 1) * 50).limit(50).to_a
      ActiveRecord::Associations::Preloader.new(records: @scenarios, associations: :current_version,
        scope: ScenarioVersion.select(:id, :workspace_id, :corpus_id, :scenario_id, :number, :title, :importance)).call
    end
    render :index, status: :unprocessable_content if @search_error
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
    @conversation_evidence = @version.scenario_evidence.joins(corpus_item: { source_snapshot: :source })
      .find_by(corpus_item_id: @scenario.corpus_item_id, kind: "expectation", sources: { kind: "conversations" })
    @document_query = params[:corpus_query].to_s
    query = @document_query.strip
    @corpus.with_lock do
      documents = @corpus.evidence_items.where(sources: { kind: "document" })
      if query.length > 200 || query.include?("\0")
        @document_search_error = "Document search needs at most 200 characters and no null bytes. Shorten the phrase and try again."
        documents = documents.none
      elsif query.present?
        pattern = ActiveRecord::Relation::QueryAttribute.new("corpus_query",
          "%#{ActiveRecord::Base.sanitize_sql_like(query)}%", CorpusItem.type_for_attribute("content"))
        documents = documents.where("corpus_items.title ILIKE :pattern OR corpus_items.external_id ILIKE :pattern OR corpus_items.content ILIKE :pattern", pattern:)
      end
      @document_count = documents.count
      @evidence_items = documents.select(:id, :title).order(:id).limit(100).to_a
    end
    if params[:trace_item_id].present?
      @trace_item = @corpus.evidence_items.where(sources: { kind: "traces" }).find(params.expect(:trace_item_id))
      @evidence_items.unshift(@trace_item)
    end
    @proposal = @version.scenario_proposal
    begin
      @proposal_input = ScenarioExtractor.input(@version) unless @proposal
    rescue Scenario::Invalid => error
      @proposal_input_error = error.message
    end
    @form_values ||= {}
    render :show, status: :unprocessable_content if action_name == "show" && @document_search_error
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
    values = params.expect(scenario: [ :title, :situation, :taxonomy_label, :importance, :known_facts, :hidden_facts, :follow_ups, *ScenarioVersion::REQUIREMENT_TYPES.map(&:to_sym) ]).to_h
    @form_values = values.dup
    values["known_facts"] = JSON.parse(values["known_facts"].to_s)
    values["hidden_facts"] = JSON.parse(values["hidden_facts"].to_s)
    values["follow_ups"] = JSON.parse(values["follow_ups"].to_s) if values.key?("follow_ups")
    values["requirements"] = ScenarioVersion::REQUIREMENT_TYPES.to_h { |kind| [ kind, values.delete(kind).to_s.lines.map(&:strip).reject(&:empty?) ] }
    previous_id = scenario.current_version_id
    version = scenario.revise!(membership: Current.require_membership!, base_version_id: params[:version_id], attributes: values,
      evidence_item_id: params[:evidence_item_id], excerpt: params[:excerpt], evidence_kind: params[:evidence_kind], conversation_excerpt: params[:conversation_excerpt])
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
        action_name == "propose" ? "Model configuration must be valid JSON. Correct it and request again." : "Facts, follow-ups and variant values must be valid JSON. Correct the value and save again."
      else
        error.message
      end
      if params[:id]
        show
        if error.is_a?(ActiveRecord::RecordInvalid) && error.record.is_a?(ScenarioEvidence)
          if params[:conversation_excerpt].present? && error.record.corpus_item_id == @scenario.corpus_item_id
            @conversation_excerpt_error = error.record.errors.full_messages.to_sentence
          else
            @evidence_error = error.record.errors.full_messages.to_sentence
          end
        end
        flash.now[:alert] = message
        render :show, status: :unprocessable_content
      else
        redirect_to workspace_corpus_scenarios_path(Current.workspace, @corpus), alert: message, status: :see_other
      end
    end
end
