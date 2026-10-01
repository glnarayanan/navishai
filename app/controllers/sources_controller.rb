class SourcesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: %i[create decide_trace]
  before_action -> { require_role(:owner, :admin, :manager) }, only: %i[destroy download_snapshot]
  before_action :load_corpus

  def create
    upload = params[:file]
    raise CorpusIntake::Invalid, "Choose an export or text document." unless upload.respond_to?(:read)
    input = if params[:kind] == "conversation_lines"
      raise CorpusIntake::Invalid, "Choose a conversation JSONL file." unless upload.respond_to?(:tempfile)
      { file: upload.tempfile }
    else
      { bytes: upload.read(CorpusIntake::MAX_BYTES + 1) }
    end
    snapshot = CorpusIntake.call(corpus: @corpus, membership: Current.require_membership!,
      name: params[:name], kind: params[:kind], **input,
      redaction: params[:redaction], retention_days: params[:retention_days], redaction_values: params[:redaction_values] || "")
    redirect_to workspace_corpus_source_path(Current.workspace, @corpus, snapshot.source),
      notice: "Snapshot #{snapshot.number} retained; #{snapshot.corpus_items.count} source-backed records.", status: :see_other
  rescue CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    flash[:intake_redaction] = params[:redaction] if %w[email none exact].include?(params[:redaction])
    flash[:intake_kind] = params[:kind] if %w[conversations conversation_lines document traces].include?(params[:kind])
    redirect_to workspace_corpus_path(Current.workspace, @corpus), alert: error.message, status: :see_other
  end

  def show
    @source = @corpus.sources.where("expires_at > ?", Time.current).find(params[:id])
    @snapshots = @source.source_snapshots.order(number: :desc)
    @snapshot = params[:snapshot] ? @snapshots.find_by!(number: params[:snapshot]) : @source.current_snapshot
    @page = [ params[:page].to_i, 1 ].max
    @corpus.with_lock do
      @matching_count = @snapshot.corpus_items.count
      @more = @matching_count > @page * 50
      page_items = @snapshot.corpus_items.order(:id).offset((@page - 1) * 50).limit(50)
      bytes = @snapshot.corpus_items.where(id: page_items.select(:id)).sum(CorpusAnalysis::RECORD_BYTES_SQL)
      if bytes > CorpusAnalysis::MAX_RECORD_BYTES
        @evidence_read_error = "This complete evidence page exceeds 10 MiB. Search current records with a narrower phrase or source, or try the next page if available; no page records were loaded. Current-record search does not include historical snapshots."
        @items = []
      else
        @items = page_items.to_a
      end
    end
    @dependency_page = params[:dependency_page].to_i.clamp(1, 10000)
    dependencies = @source.dependent_versions
    @dependencies = dependencies.includes(:scenario).order(id: :desc).offset((@dependency_page - 1) * 50).limit(51).to_a
    @more_dependencies = @dependencies.size > 50
    @dependencies = @dependencies.first(50)
    @case_page = params[:case_page].to_i.clamp(1, 10000)
    @dependent_cases = @corpus.eval_cases.where(scenario_version_id: dependencies.select(:id)).includes(:scenario_version).order(id: :desc).offset((@case_page - 1) * 50).limit(51).to_a
    @more_cases = @dependent_cases.size > 50
    @dependent_cases = @dependent_cases.first(50)
    @suite_memberships = EvalSuiteCase.where(corpus: @corpus, eval_case_id: @dependent_cases.map(&:id)).includes(:eval_suite).order(:id).group_by(&:eval_case_id)
    if @source.kind == "traces"
      @trace_scenarios = @corpus.scenarios.where(corpus_item_id: @items.map(&:id), parent_version_id: nil).index_by(&:corpus_item_id)
      @matching_item_id = params[:matching_item_id].to_s
      @matching_page = params[:matching_page].to_i.clamp(1, 10000)
      @trace_match_counts = {}
      @trace_matching_blocked = @corpus.eval_definitions_expired?
      @trace_matches = @items.to_h do |item|
        cases = @trace_matching_blocked ? @corpus.eval_cases.none : @corpus.eval_cases.matching_trace(item)
        @trace_match_counts[item.id] = cases.count
        matching_page = @matching_item_id == item.id.to_s ? @matching_page : 1
        [ item.id, cases.order(:id).offset((matching_page - 1) * 50).limit(50).pluck(:id, "scenario_versions.title") ]
      end
      @failure_candidates = TraceScenarioMatching.call_all(items: @items)
      @decision_page = params[:decision_page].to_i.clamp(1, 10000)
      @trace_decisions = {}
      unless @corpus.eval_definitions_expired?
        decisions = TraceScenarioDecision.where(corpus: @corpus, corpus_item_id: @items.map(&:id))
        @latest_decision_ids = decisions.group(:corpus_item_id, :scenario_version_id, :reviewed_by_id).maximum(:id).values
        history = decisions.includes(:reviewed_by, scenario_version: :scenario).order(id: :desc).offset((@decision_page - 1) * 50).limit(51).to_a
        @more_decisions = history.size > 50
        @trace_decisions = history.first(50).group_by(&:corpus_item_id)
        if params.key?(:selected_scenario_id)
          @selected_trace = @items.find { |item| item.id.to_s == params[:selected_trace_id].to_s }
          raise ActiveRecord::RecordNotFound unless @selected_trace

          @corpus.with_lock do
            @selected_scenario = @corpus.scenarios.find_by(id: params[:selected_scenario_id])
            @selected_version = if @decision_form
              @selected_scenario&.scenario_versions&.find_by(id: @decision_form["scenario_version_id"])
            else
              @selected_scenario&.current_version
            end
            @selected_eligible = @selected_version && TraceScenarioMatching.eligible?(@selected_version) && SupportTrace.payload(@selected_trace)["observed_failure"].present?
          end
        end
      end
    end
  end

  def decide_trace
    @source = @corpus.sources.where(kind: "traces").where("expires_at > ?", Time.current).find(params[:id])
    @item = @corpus.corpus_items.joins(:source_snapshot).where(source_snapshots: { source_id: @source.id }).find(params[:corpus_item_id])
    version = ScenarioVersion.where(corpus: @corpus).find(params[:scenario_version_id])
    TraceScenarioDecision.append!(item: @item, version:, membership: Current.require_membership!, decision: params[:decision], reason: params[:reason])
    redirect_to helpers.source_evidence_path(@item), notice: "Trace decision appended. Scenario approval and replay compatibility are unchanged.", status: :see_other
  rescue Scenario::Invalid, CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    @decision_error = error.message
    @decision_form = params.permit(:corpus_item_id, :scenario_version_id, :decision, :reason, :selected_scenario_id).to_h
    params[:selected_trace_id] = @item.id if params.key?(:selected_scenario_id)
    params[:snapshot] = @item.source_snapshot.number
    params[:page] = @item.source_snapshot.corpus_items.where("id < ?", @item.id).count / 50 + 1
    show
    render :show, status: :unprocessable_content
  end

  def download_snapshot
    @source = @corpus.sources.where(workspace_id: Current.workspace.id).find(params[:id])
    @snapshot = @source.source_snapshots.where(workspace_id: Current.workspace.id, corpus_id: @corpus.id).find(params[:snapshot_id])
    json = @source.download_snapshot!(snapshot_id: @snapshot.id, membership: Current.require_membership!, confirmation: params[:download_confirmation])
    response.headers["Cache-Control"] = "no-store"
    send_data json, type: "application/json", disposition: "attachment",
      filename: "source-#{@source.id}-snapshot-#{@snapshot.id}.json"
  rescue CorpusIntake::Invalid => error
    @download_error = error.message
    @download_confirmation = params[:download_confirmation]
    params[:snapshot] = @snapshot.number
    show
    render :show, status: :unprocessable_content
  end

  def destroy
    source = @corpus.sources.find(params[:id])
    if params[:confirmation] != source.name
      redirect_to workspace_corpus_source_path(Current.workspace, @corpus, source), alert: "Type the source name to confirm deletion.", status: :see_other
      return
    end
    SourcePurge.call(source:, membership: Current.require_membership!)
    redirect_to workspace_corpus_path(Current.workspace, @corpus), notice: "Source snapshots and their records deleted.", status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end
end
