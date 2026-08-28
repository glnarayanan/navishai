class HealthEvidence
  Entry = Data.define(:kind, :title, :detail, :path)

  attr_reader :workspace, :account, :assessment, :signal

  def initialize(workspace:, account:, assessment:, signal:)
    @workspace = workspace
    @account = workspace.accounts.find(account.id)
    @assessment = account.health_assessments.find(assessment.id)
    @signal = assessment.signals.find(signal.id)
  end

  def entries
    @entries ||= begin
      records = signal.evidence_refs.group_by { |reference| reference.fetch("kind") }.transform_values do |references|
        records_for(references.first.fetch("kind"), references.pluck("id"))
      end
      signal.evidence_refs.filter_map do |reference|
        record = records.fetch(reference.fetch("kind"))[reference.fetch("id")]
        entry_for(reference.fetch("kind"), record) if record
      end
    end
  end

  private
    def case_ids
      @case_ids ||= workspace.support_cases.joins(conversation: :contact)
        .where(contacts: { account_id: account.id }).select(:id)
    end

    def records_for(kind, ids)
      scope = case kind
      when "support_case"
        workspace.support_cases.where(id: ids).where(id: case_ids).includes(:conversation)
      when "case_sla"
        workspace.case_slas.where(id: ids, support_case_id: case_ids).includes(support_case: :conversation)
      when "case_note"
        workspace.case_notes.where(id: ids, support_case_id: case_ids).includes(support_case: :conversation)
      when "conversation_message"
        workspace.conversation_messages.joins(conversation: :contact)
          .where(id: ids, contacts: { account_id: account.id }).includes(:conversation)
      when "support_case_status_change"
        workspace.support_case_status_changes.where(id: ids, support_case_id: case_ids)
          .includes(support_case: :conversation)
      when "tag"
        workspace.tags.where(id: ids)
      when "crew_artifact"
        workspace.crew_artifacts.joins(:crew_task).where(id: ids, crew_tasks: { support_case_id: case_ids })
          .includes(crew_task: { support_case: :conversation })
      when "account_health_input"
        workspace.account_health_inputs.where(id: ids, account_id: account.id).includes(:corrects_input)
      else
        AccountHealthInput.none
      end
      scope.index_by(&:id)
    end

    def entry_for(kind, record)
      case kind
      when "support_case"
        Entry.new(kind:, title: record.conversation.subject.presence || "Untitled case",
          detail: "#{record.status.humanize} · #{record.priority} priority", path: case_path(record))
      when "case_sla"
        Entry.new(kind:, title: record.support_case.conversation.subject.presence || "Untitled case",
          detail: "First response #{record.first_response_status.humanize}; resolution #{record.resolution_status.humanize}",
          path: case_path(record.support_case))
      when "case_note"
        Entry.new(kind:, title: record.support_case.conversation.subject.presence || "Untitled case",
          detail: "Internal note · #{record.created_at.to_fs(:short)} · #{record.body.to_s.truncate(160)}",
          path: case_path(record.support_case))
      when "conversation_message"
        Entry.new(kind:, title: record.conversation.subject.presence || "Customer conversation",
          detail: "#{record.direction.humanize} · #{record.occurred_at.to_fs(:short)} · #{record.body.to_s.truncate(160)}",
          path: conversation_case_path(record.conversation))
      when "support_case_status_change"
        Entry.new(kind:, title: record.support_case.conversation.subject.presence || "Untitled case",
          detail: "#{record.from_status.humanize} → #{record.to_status.humanize} · #{record.occurred_at.to_fs(:short)}",
          path: case_path(record.support_case))
      when "tag"
        Entry.new(kind:, title: record.name, detail: "Human-applied tag retained on at least two cases", path: nil)
      when "crew_artifact"
        Entry.new(kind:, title: record.crew_task.support_case.conversation.subject.presence || "Resolution proof",
          detail: "#{record.artifact_kind.humanize} · contract #{record.contract_result_state.humanize} · #{record.contract_evaluated_at.to_fs(:short)}",
          path: crew_task_path(record.crew_task))
      when "account_health_input"
        correction = record.corrects_input ? " · corrects source #{record.corrects_input.source_key}" : ""
        Entry.new(kind:, title: record.input_key.humanize,
          detail: "#{record.source_namespace} / #{record.source_key}#{correction} · observed #{record.observed_at.to_fs(:short)}",
          path: nil)
      end
    end

    def case_path(support_case)
      Rails.application.routes.url_helpers.workspace_support_case_path(workspace, support_case)
    end

    def conversation_case_path(conversation)
      support_case = workspace.support_cases.find_by(conversation:)
      support_case && case_path(support_case)
    end

    def crew_task_path(task)
      Rails.application.routes.url_helpers.workspace_support_case_crew_task_path(workspace, task.support_case, task)
    end
end
