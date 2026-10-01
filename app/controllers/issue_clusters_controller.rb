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
      @corpus.with_lock do
        groups = @cluster.source_groups
        @group_counts = groups.transform_values(&:count)
        @total = @group_counts.fetch("All records")
        @filter = params[:signal].presence || "All records"
        @invalid_filter = !groups.key?(@filter)
        matching = @invalid_filter ? @cluster.cluster_members.none : groups.fetch(@filter)
        @matching_count = @invalid_filter ? 0 : @group_counts.fetch(@filter)
        @page = params[:page].to_i.clamp(1, 10000)
        @members = matching.includes(corpus_item: { source_snapshot: :source }).offset((@page - 1) * 50).limit(50).to_a
        @more = @matching_count > @page * 50
        @member_scenarios = @corpus.scenarios.where(cluster_member: @members).index_by(&:cluster_member_id)
      end
    end
end
