class EmailAttachmentWorkflow
  def self.add!(workspace:, support_case:, membership:, draft_version:, files:, scanner: AttachmentScanner.default)
    actor = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless actor.can_write?

    prepared = AttachmentIntake.prepare!(files, scanner: scanner)
    committed = false
    attachments = EmailDraft.transaction do
      actor = workspace.memberships.lock.find(actor.id)
      raise Current::RoleAccessDenied unless actor.can_write?

      current_case = workspace.support_cases.lock.find(support_case.id)
      draft = workspace.email_drafts.lock.find_by!(support_case: current_case)
      raise ActiveRecord::StaleObjectError.new(draft, "add attachments") unless draft.lock_version.to_s == draft_version.to_s
      raise ArgumentError, "sent or sending drafts cannot be changed" unless draft.ready?
      if draft.email_draft_attachments.count + prepared.size > AttachmentIntake::MAX_FILES
        raise AttachmentIntake::InvalidAttachment, "A draft can have no more than #{AttachmentIntake::MAX_FILES} files."
      end
      if draft.stored_attachments.sum(:byte_size) + prepared.sum(&:byte_size) > AttachmentIntake::MAX_TOTAL_BYTES
        raise AttachmentIntake::InvalidAttachment, "Draft attachments exceed the 10 MiB total limit."
      end

      records = AttachmentIntake.persist!(
        workspace: workspace, prepared: prepared, source: :user_upload,
        draft: draft, membership: actor
      )
      draft.update!(updated_by: actor.user)
      records.each do |attachment|
        AuditEvent.record!(
          action: "attachment.uploaded", source: :web, workspace: workspace,
          actor: actor.user, subject: attachment, metadata: { scan_status: attachment.scan_status }
        )
      end
      committed = true
      records
    end
    attachments
  ensure
    prepared&.each(&:purge!) unless committed
  end

  def self.remove!(workspace:, support_case:, membership:, attachment:, draft_version:)
    EmailDraft.transaction do
      actor = workspace.memberships.lock.find(membership.id)
      raise Current::RoleAccessDenied unless actor.can_write?

      current_case = workspace.support_cases.lock.find(support_case.id)
      draft = workspace.email_drafts.lock.find_by!(support_case: current_case)
      raise ActiveRecord::StaleObjectError.new(draft, "remove attachment") unless draft.lock_version.to_s == draft_version.to_s
      raise ArgumentError, "sent or sending drafts cannot be changed" unless draft.ready?

      current_attachment = workspace.stored_attachments.find(attachment.id)
      draft.email_draft_attachments.find_by!(stored_attachment: current_attachment).destroy!
      draft.update!(updated_by: actor.user)
      AuditEvent.record!(
        action: "attachment.removed", source: :web, workspace: workspace,
        actor: actor.user, subject: draft, metadata: { attachment_id: current_attachment.id }
      )
      draft
    end
  end
end
