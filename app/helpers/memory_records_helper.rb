module MemoryRecordsHelper
  def memory_topic_label(memory)
    memory.topic.tr("-", " ").humanize
  end

  def memory_state(memory)
    return [ "Deleted", "status-danger" ] if memory.memory_tombstone
    return [ "Superseded", "status-neutral" ] if memory.revisions.any?
    return [ "Expired", "status-warning" ] unless memory.eligible_at?(Time.current)

    [ "Current", "status-success" ]
  end

  def memory_scope_label(memory)
    target = memory.scope_target
    name = case target
    when Workspace, Organization then target.name
    when Account, Contact then target.name.presence || "Record ##{target.id}"
    when SupportCase then target.conversation.subject.presence || "Case ##{target.id}"
    when CrewTemplate, AgentProfile then target.name
    when User then "Workspace user"
    end
    "#{memory.scope_kind.humanize}: #{name}"
  end

  def memory_authority_label(memory)
    {
      "human_correction" => "Human correction",
      "source_record" => "Source record",
      "inference" => "Inference"
    }.fetch(memory.authority)
  end

  def memory_retention_label(memory)
    return "Until #{memory.retention_until.to_fs(:long)}" if memory.retention_policy_time_bound?

    memory.retention_policy.humanize
  end
end
