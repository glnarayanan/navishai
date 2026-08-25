module Auditing
  extend ActiveSupport::Concern

  private
    def audit_event(action, workspace: Current.workspace, actor: Current.user, subject: nil, metadata: {})
      AuditEvent.record!(
        action: action,
        source: :web,
        workspace: workspace,
        actor: actor,
        subject: subject,
        metadata: metadata,
        request_id: request.request_id,
        ip_address: request.remote_ip
      )
    end
end
