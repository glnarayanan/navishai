class EmailDraftWorkflow
  def self.save!(workspace:, support_case:, membership:, body:, expected_lock_version: nil)
    EmailDraft.transaction do
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write?

      current_case = workspace.support_cases.lock.find(support_case.id)
      thread = workspace.email_threads.find_by!(conversation_id: current_case.conversation_id)
      draft = workspace.email_drafts.lock.find_or_initialize_by(support_case: current_case)
      if expected_lock_version && expected_lock_version != (draft.persisted? ? draft.lock_version.to_s : "new")
        raise ActiveRecord::StaleObjectError.new(draft, "save")
      end
      raise ArgumentError, "sent or sending drafts cannot be edited" unless draft.new_record? || draft.ready?

      draft.assign_attributes(email_thread: thread, conversation: current_case.conversation, updated_by: actor.user, body: body)
      draft.save!
      AuditEvent.record!(action: "email.draft_saved", source: :web, workspace: workspace, actor: actor.user, subject: draft)
      draft
    end
  end
end
