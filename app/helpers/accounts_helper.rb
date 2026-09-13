module AccountsHelper
  ACCOUNT_WORK_VIEW_LABELS = {
    "needs_attention" => "Needs attention",
    "renewal_approaching" => "Renewal approaching",
    "interventions_awaiting_approval" => "Awaiting approval",
    "interventions_overdue" => "Overdue",
    "completed_awaiting_outcome_review" => "Outcome review",
    "all_accounts" => "All accounts"
  }.freeze

  ACCOUNT_WORK_REASON_LABELS = {
    "health_unknown" => "Health not scored",
    "material_change" => "Material health change",
    "open_investigation" => "Open risk review",
    "renewal_approaching" => "Renewal approaching",
    "intervention_awaiting_approval" => "Intervention awaiting approval",
    "intervention_overdue" => "Intervention overdue",
    "completed_awaiting_outcome_review" => "Completed intervention needs outcome review"
  }.freeze

  ACCOUNT_WORK_EMPTY = {
    "needs_attention" => [
      "No accounts need attention",
      "Accounts appear here when health is missing, a comparable material change exists, a risk review is open, or an intervention is waiting. Approaching renewals stay in their own view."
    ],
    "renewal_approaching" => [
      "No renewals in the 90-day window",
      "Unknown renewal dates are not treated as approaching. They remain visible on All accounts as unknown."
    ],
    "interventions_awaiting_approval" => [
      "No interventions await approval",
      "Proposed interventions that still need a Manager decision appear here."
    ],
    "interventions_overdue" => [
      "No overdue interventions",
      "Proposed or approved follow-ups whose target date has passed appear here."
    ],
    "completed_awaiting_outcome_review" => [
      "No completed interventions need outcome review",
      "Human-completed interventions stay here until a Manager records the observed outcome."
    ],
    "all_accounts" => [
      "No accounts yet",
      "Sync Intercom or import account data to create the first health record."
    ]
  }.freeze

  def account_work_view_label(view) = ACCOUNT_WORK_VIEW_LABELS.fetch(view.to_s)

  def account_work_reason_label(reason) = ACCOUNT_WORK_REASON_LABELS.fetch(reason.to_s, reason.to_s.humanize)

  def account_work_index_params(view: @view, page: @page)
    query = { view: }
    query[:page] = page if page.to_i > 1
    query
  end

  def account_work_account_path(row)
    workspace_account_path(
      @workspace, row.account,
      **account_work_index_params,
      anchor: row.action_anchor
    )
  end
end
