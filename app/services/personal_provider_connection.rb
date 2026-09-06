class PersonalProviderConnection
  def self.disconnect_membership!(membership:, gateway: PersonalProviderGateway.new)
    PersonalProviderAccount.where(workspace_id: membership.workspace_id, membership_id: membership.id)
      .where.not(state: "disconnected").find_each do |account|
      result = gateway.account(action: "disconnect", workspace_key: membership.workspace.runner_key,
        membership_id: membership.id, account_key: account.account_key)
      refresh!(account:, result:)
      AuditEvent.record!(action: "runtime.personal_account_disconnected", workspace: membership.workspace,
        actor_kind: :system, source: :system, subject: account)
    end
  end

  def self.refresh!(account:, result:)
    account.with_lock do
      account.update!(state: result.fetch("state"), expires_at: result["expires_at"])
      installation = account.runtime_installation
      if account.connected?
        report = result.fetch("installation")
        test = result.fetch("runtime_test")
        installation ||= account.build_runtime_installation(workspace: account.workspace)
        changed = installation.persisted? && installation.configuration_fingerprint != report.fetch("configuration_fingerprint")
        revoke(installation) if changed
        installation.assign_attributes(report.slice(*RuntimeInstallation.column_names))
        installation.assign_attributes(
          runtime_test_status: "passed", runtime_tested_at: test.fetch("tested_at"),
          runtime_tested_configuration_fingerprint: report.fetch("configuration_fingerprint"),
          runtime_test_failure_code: nil, runtime_test_input_units: test.fetch("input_units"),
          runtime_test_output_units: test.fetch("output_units"), runtime_test_usage_observed: test.fetch("usage_observed")
        )
        installation.save!
      elsif installation
        revoke(installation)
        installation.update!(health_status: "missing", checked_at: Time.current)
      end
    end
    account
  end

  def self.revoke(installation)
    installation.assign_attributes(approved: false, approved_by_user: nil, approved_by_membership: nil, approved_at: nil)
  end
  private_class_method :revoke
end
