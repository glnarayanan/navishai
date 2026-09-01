class AddRuntimeConfigurationAndTestEvidence < ActiveRecord::Migration[8.1]
  def change
    change_table :runtime_installations, bulk: true do |t|
      t.string :effective_model, null: false, default: "runtime_default"
      t.string :configuration_fingerprint, null: false, default: "0" * 64
      t.string :runtime_test_status, null: false, default: "untested"
      t.string :runtime_test_failure_code
      t.datetime :runtime_tested_at
      t.string :runtime_tested_configuration_fingerprint
      t.bigint :runtime_test_input_units, null: false, default: 0
      t.bigint :runtime_test_output_units, null: false, default: 0
      t.boolean :runtime_test_usage_observed, null: false, default: false
    end

    add_check_constraint :runtime_installations,
      "octet_length(effective_model) BETWEEN 1 AND 200 AND effective_model !~ '[\\r\\n]' AND " \
      "configuration_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "runtime_installations_configuration_identity"
    add_check_constraint :runtime_installations,
      "runtime_test_status IN ('untested', 'passed', 'failed') AND " \
      "(runtime_test_failure_code IS NULL OR runtime_test_failure_code ~ '^[a-z][a-z0-9_]{0,99}$') AND " \
      "(runtime_tested_configuration_fingerprint IS NULL OR runtime_tested_configuration_fingerprint ~ '^[0-9a-f]{64}$') AND " \
      "runtime_test_input_units >= 0 AND runtime_test_output_units >= 0",
      name: "runtime_installations_test_evidence"
    add_check_constraint :runtime_installations,
      "(runtime_test_status = 'untested' AND runtime_test_failure_code IS NULL AND runtime_tested_at IS NULL AND " \
      "runtime_tested_configuration_fingerprint IS NULL AND runtime_test_input_units = 0 AND runtime_test_output_units = 0 AND " \
      "runtime_test_usage_observed = false) OR " \
      "(runtime_test_status = 'passed' AND runtime_test_failure_code IS NULL AND runtime_tested_at IS NOT NULL AND " \
      "runtime_tested_configuration_fingerprint = configuration_fingerprint) OR " \
      "(runtime_test_status = 'failed' AND runtime_test_failure_code IS NOT NULL AND runtime_tested_at IS NOT NULL AND " \
      "runtime_tested_configuration_fingerprint = configuration_fingerprint)",
      name: "runtime_installations_test_state"
  end
end
