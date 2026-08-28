class IntercomDraftWorkflow
  def self.follow_up_available?(draft)
    return false unless draft.sent?

    delivery = draft.intercom_outbound_deliveries.sent.order(sent_at: :desc, id: :desc).first
    return false unless delivery

    latest = draft.intercom_conversation_link.intercom_part_links.where.not(part_type: :note)
      .order(remote_created_at: :desc, id: :desc).first
    latest&.contact_reply? && latest.remote_part_id != delivery.remote_part_id
  end

  def self.save!(workspace:, support_case:, membership:, body:, expected_lock_version: nil,
    source_crew_artifact_id: nil, adopt_source: false)
    IntercomDraft.transaction do
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write?

      current_case = workspace.support_cases.lock.find(support_case.id)
      link = workspace.intercom_conversation_links.find_by!(conversation_id: current_case.conversation_id)
      draft = workspace.intercom_drafts.lock.find_or_initialize_by(support_case: current_case)
      expected = draft.persisted? ? draft.lock_version.to_s : "new"
      raise ActiveRecord::StaleObjectError.new(draft, "save") if expected_lock_version && expected_lock_version.to_s != expected
      follow_up = draft.sent?
      if follow_up
        raise ArgumentError, "a new customer message is required before another reply" unless follow_up_available?(draft)

        draft.status = :ready
      elsif draft.persisted? && !draft.ready?
        raise ArgumentError, "sent or sending drafts cannot be edited"
      end

      HumanDraftProvenance.apply!(
        draft:, workspace:, support_case: current_case, membership: actor, body:,
        source_crew_artifact_id:, adopt_source:, follow_up:
      )
      draft.assign_attributes(
        intercom_conversation_link: link, conversation: current_case.conversation,
        updated_by: actor.user, body: body
      )
      draft.save!
      AuditEvent.record!(action: "intercom.draft_saved", source: :web, workspace: workspace, actor: actor.user, subject: draft)
      draft
    end
  end
end
