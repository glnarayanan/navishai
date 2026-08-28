module AccountDossiersHelper
  def dossier_record_path(dossier, record)
    case record
    when SupportCase
      workspace_support_case_path(dossier.workspace, record)
    when CrewTask
      if record.support_case
        workspace_support_case_crew_task_path(dossier.workspace, record.support_case, record)
      else
        workspace_account_crew_task_path(dossier.workspace, record.account, record)
      end
    when AccountRiskInvestigation
      workspace_account_path(dossier.workspace, dossier.account, anchor: "risk-reviews")
    when CustomerSuccessIntervention
      workspace_account_path(dossier.workspace, dossier.account, anchor: "customer-success-interventions")
    when MemoryRecord
      workspace_memory_record_path(dossier.workspace, record)
    end
  end

  def dossier_input_value(input)
    input.value_kind == "date" ? input.date_value.to_fs(:long) : number_with_delimiter(input.numeric_value)
  end

  def dossier_memory_retention(record)
    return "Deleted from retrieval" if record.memory_tombstone
    return "Retained until #{record.retention_until.to_fs(:long)}" if record.retention_policy_time_bound?
    return "Retained with source" if record.retention_policy_source_lifetime?

    "Retained indefinitely"
  end
end
