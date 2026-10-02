class SourcesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: :create
  before_action -> { require_role(:owner, :admin, :manager) }, only: :destroy
  before_action :load_corpus

  def create
    upload = params[:file]
    raise CorpusIntake::Invalid, "Choose an export or text document." unless upload.respond_to?(:read)
    snapshot = CorpusIntake.call(corpus: @corpus, membership: Current.require_membership!,
      name: params[:name], kind: params[:kind], bytes: upload.read(CorpusIntake::MAX_BYTES + 1),
      redaction: params[:redaction], retention_days: params[:retention_days])
    redirect_to workspace_corpus_source_path(Current.workspace, @corpus, snapshot.source),
      notice: "Snapshot #{snapshot.number} retained; #{snapshot.corpus_items.count} source-backed records.", status: :see_other
  rescue CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    redirect_to workspace_corpus_path(Current.workspace, @corpus), alert: error.message, status: :see_other
  end

  def show
    @source = @corpus.sources.where("expires_at > ?", Time.current).find(params[:id])
    @snapshots = @source.source_snapshots.order(number: :desc)
    @snapshot = params[:snapshot] ? @snapshots.find_by!(number: params[:snapshot]) : @source.current_snapshot
    @page = [ params[:page].to_i, 1 ].max
    @items = @snapshot.corpus_items.order(:id).offset((@page - 1) * 50).limit(51).to_a
    @more = @items.size > 50
    @items = @items.first(50)
    if @source.kind == "traces"
      @trace_scenarios = @corpus.scenarios.where(corpus_item_id: @items.map(&:id), parent_version_id: nil).index_by(&:corpus_item_id)
      cases = @corpus.eval_definitions_expired? ? [] : @corpus.eval_cases.includes(:scenario_version).order(:id).limit(100)
      inputs = cases.to_h { |item| [ item, item.scenario_version.target_input ] }
      @trace_matches = @items.to_h do |item|
        recorded_input = SupportTrace.payload(item)["input"]
        [ item.id, inputs.select { |_eval_case, input| input == recorded_input }.keys ]
      end
    end
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
