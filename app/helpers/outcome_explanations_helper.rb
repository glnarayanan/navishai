module OutcomeExplanationsHelper
  def explanation_back_path(explanation)
    case explanation.subject
    when SupportCase
      workspace_support_case_path(explanation.workspace, explanation.subject)
    when Account
      workspace_account_path(explanation.workspace, explanation.subject)
    when ExecutionRun
      task = explanation.subject.crew_task
      if task.support_case
        workspace_support_case_crew_task_path(explanation.workspace, task.support_case, task)
      else
        workspace_account_crew_task_path(explanation.workspace, task.account, task)
      end
    when AccountHealthAssessment
      workspace_account_path(explanation.workspace, explanation.subject.account, anchor: "health-assessment")
    end
  end

  def format_usage_money(currency, amount_micros)
    amount = BigDecimal(amount_micros.to_s) / 1_000_000
    "#{currency} #{format('%.6f', amount)}"
  end

  def explanation_task_path(explanation, task)
    if task.support_case
      workspace_support_case_crew_task_path(explanation.workspace, task.support_case, task)
    else
      workspace_account_crew_task_path(explanation.workspace, task.account, task)
    end
  end
end
