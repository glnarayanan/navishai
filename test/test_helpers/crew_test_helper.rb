module CrewTestHelper
  private
    def install_crew_test_dependencies(workspace:, membership:)
      installation = workspace.runtime_installations.find_by(adapter_key: "scripted")
      unless installation
        installation = runtime_installations(:acme_scripted).dup
        installation.assign_attributes(
          workspace:, detection_key: Digest::SHA256.hexdigest("scripted:#{workspace.id}")
        )
      end
      installation.assign_attributes(
        runtime_test_status: "passed", runtime_tested_at: Time.current,
        runtime_tested_configuration_fingerprint: installation.configuration_fingerprint,
        approved: true, approved_by_membership: membership, approved_by_user: membership.user,
        approved_at: Time.current
      )
      installation.save!
      CrewConfiguration.install_defaults!(workspace:)
      ResolutionContractConfiguration.install_defaults!(workspace:)
    end
end
