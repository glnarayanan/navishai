class IssueClustersController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace

  def show
    @corpus = Current.workspace.corpora.find(params[:corpus_id])
    @analysis = @corpus.corpus_analyses.find(params[:corpus_analysis_id])
    raise ActiveRecord::RecordNotFound if @analysis.expired?
    @cluster = @analysis.issue_clusters.find(params[:id])
    @groups = @cluster.source_groups
    @total = @groups.fetch("All records").size
    @filter = params[:signal].presence || "All records"
    @invalid_filter = !@groups.key?(@filter)
    @matching = @invalid_filter ? [] : @groups.fetch(@filter)
    @page = params[:page].to_i.clamp(1, 10000)
    @members = @matching.slice((@page - 1) * 50, 50) || []
    @more = @matching.size > @page * 50
    render :show, status: :unprocessable_content if @invalid_filter
  end
end
