module RunPanelFreshness
  extend ActiveSupport::Concern

  RUN_PANEL_TEMPLATE = "crew_tasks/_execution_runs"

  included do
    helper_method :run_panel_etag_value
  end

  private
    def run_panel_version
      [
        @task, @membership, Current.session, crew_task_runs_path(@task),
        I18n.locale, Time.zone.name,
        @task.execution_runs.cache_key_with_version,
        @task.artifacts.cache_key_with_version
      ]
    end

    def run_panel_etag_value
      %(W/"#{ActiveSupport::Digest.hexdigest(ActiveSupport::Cache.expand_cache_key(run_panel_etag_validators))}")
    end

    def run_panel_etag_validators
      [
        run_panel_version,
        ActionView::Digestor.digest(name: RUN_PANEL_TEMPLATE, format: nil, finder: lookup_context)
      ]
    end
end
