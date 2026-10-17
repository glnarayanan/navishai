module NavigationHelper
  ICONS = {
    overview: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9v11h14V9"/>',
    corpora: '<ellipse cx="12" cy="5.5" rx="8" ry="2.5"/><path d="M4 5.5v13c0 1.4 3.6 2.5 8 2.5s8-1.1 8-2.5v-13"/><path d="M4 12c0 1.4 3.6 2.5 8 2.5s8-1.1 8-2.5"/>',
    people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20.5c0-3.6 2.9-6.5 6.5-6.5s6.5 2.9 6.5 6.5"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8"/><path d="M21.5 20.5c0-2.8-1.6-5.1-4-6.1"/>',
    settings: '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
    workspaces: '<rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/>',
    sources: '<path d="M14 3H6.5A1.5 1.5 0 0 0 5 4.5v15A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V8z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
    scenarios: '<path d="m3.5 6.5 1.5 1.5 3-3M3.5 13.5 5 15l3-3"/><path d="M11 6.5h9.5M11 13.5h9.5M11 20h9.5"/>',
    graders: '<rect x="3.5" y="3.5" width="17" height="17" rx="3"/><path d="m8 12 3 3 5-6"/>',
    calibration: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r=".75"/>',
    suites: '<path d="M12 3.5 2.5 8.5l9.5 5 9.5-5z"/><path d="m2.5 13 9.5 5 9.5-5"/>',
    targets: '<path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/>',
    runs: '<circle cx="12" cy="12" r="8.5"/><path d="M10.25 8.75v6.5l5.25-3.25z"/>',
    trace_discovery: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.4-4.4"/>',
    impacts: '<circle cx="6" cy="6" r="2.25"/><circle cx="18" cy="18" r="2.25"/><path d="M6 8.25V15a3 3 0 0 0 3 3h6.75M18 15.75V9a3 3 0 0 0-3-3H8.25"/>',
    chevrons: '<path d="m8 9 4-4 4 4M8 15l4 4 4-4"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    close: '<path d="M6 6l12 12M18 6 6 18"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    sign_out: '<path d="M15 4h3.5A1.5 1.5 0 0 1 20 5.5v13a1.5 1.5 0 0 1-1.5 1.5H15"/><path d="M10 8l-4 4 4 4M6 12h10"/>',
    system: '<rect x="3" y="4" width="18" height="12.5" rx="2"/><path d="M8 20.5h8M12 16.5v4"/>',
    light: '<circle cx="12" cy="12" r="3.75"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
    dark: '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>'
  }.freeze

  # Ordered as the evaluation workflow runs. Each entry lists the controllers that belong to it.
  CORPUS_SECTIONS = [
    [ :sources, "Sources", :workspace_corpus_path, %w[corpora sources corpus_analyses issue_clusters] ],
    [ :scenarios, "Scenarios", :workspace_corpus_scenarios_path, %w[scenarios] ],
    [ :graders, "Graders", :workspace_corpus_graders_path, %w[graders] ],
    [ :calibration, "Calibration", :workspace_corpus_calibration_sets_path, %w[calibration_sets calibration_samples] ],
    [ :suites, "Eval suites", :workspace_corpus_eval_suites_path, %w[eval_suites eval_cases] ],
    [ :targets, "Targets", :workspace_corpus_evaluation_targets_path, %w[evaluation_targets] ],
    [ :runs, "Runs", :workspace_corpus_evaluation_runs_path, %w[evaluation_runs evaluation_results] ],
    [ :trace_discovery, "Trace discovery", :workspace_corpus_trace_failure_discoveries_path, %w[trace_failure_discoveries] ],
    [ :impacts, "Source changes", :workspace_corpus_assumption_impacts_path, %w[assumption_impacts] ]
  ].freeze

  def nav_icon(name, css: "icon")
    tag.svg(ICONS.fetch(name).html_safe, class: css, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
      "stroke-width": 1.6, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false")
  end

  def current_membership
    return unless Current.workspace && Current.user

    @current_membership ||= Current.user.memberships.find_by(workspace: Current.workspace)
  end

  def sidebar_corpus
    @corpus if Current.workspace && @corpus.is_a?(Corpus) && @corpus.persisted?
  end

  def corpus_sections(corpus)
    CORPUS_SECTIONS.map do |key, label, route, controllers|
      { key:, label:, path: public_send(route, Current.workspace, corpus), current: controllers.include?(controller_name) }
    end
  end

  def current_corpus_section
    CORPUS_SECTIONS.find { |_key, _label, _route, controllers| controllers.include?(controller_name) }&.second
  end

  def workspace_section
    return :overview if controller_name == "workspaces" && action_name == "show"
    return :settings if controller_name == "workspaces" && action_name.in?(%w[edit update])
    return :people if controller_name.start_with?("workspace_invitation")

    :corpora if controller_name == "corpora" && action_name.in?(%w[index create])
  end

  def initials(name)
    name.to_s.scan(/[[:alnum:]]+/).first(2).map { |word| word[0] }.join.upcase.presence || "?"
  end
end
