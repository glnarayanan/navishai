class IssueClustersController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: :nominate
  before_action :load_cluster

  def show
    prepare_page
    render :show, status: :unprocessable_content if @invalid_filter
  end

  def nominate
    @nomination_member = @cluster.cluster_members.find(params.expect(:member_id))
    @nomination_reason = params[:selection_reason]
    scenario = ScenarioMining.call(analysis: @analysis, membership: Current.require_membership!, member_id: @nomination_member.id, reason: @nomination_reason).sole
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario), notice: "Scenario ready for inspection. A new draft needs expert review; existing versions and decisions stay unchanged.", status: :see_other
  rescue Scenario::Invalid, CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    @nomination_error = error.message
    prepare_page
    render :show, status: :unprocessable_content
  end

  private
    def load_cluster
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      @analysis = @corpus.corpus_analyses.find(params[:corpus_analysis_id])
      raise ActiveRecord::RecordNotFound if @analysis.expired?
      @cluster = @analysis.issue_clusters.find(params[:id])
    end

    def prepare_page
      @groups = @cluster.source_groups
      @total = @groups.fetch("All records").size
      @filter = params[:signal].presence || "All records"
      @invalid_filter = !@groups.key?(@filter)
      @matching = @invalid_filter ? [] : @groups.fetch(@filter)
      @page = params[:page].to_i.clamp(1, 10000)
      @members = @matching.slice((@page - 1) * 50, 50) || []
      @more = @matching.size > @page * 50
      @member_scenarios = @corpus.scenarios.where(cluster_member: @members).index_by(&:cluster_member_id)
    end
end
