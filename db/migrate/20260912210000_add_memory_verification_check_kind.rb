class AddMemoryVerificationCheckKind < ActiveRecord::Migration[8.1]
  KINDS_BEFORE = "check_kind IN ('archive_verification', 'attachment_scanner', 'backup_verification', 'restore_rehearsal', 'upgrade_preflight')".freeze
  KINDS_AFTER = "check_kind IN ('archive_verification', 'attachment_scanner', 'backup_verification', 'memory_verification', 'restore_rehearsal', 'upgrade_preflight')".freeze
  RESULTS_BEFORE = "result IN ('passed', 'failed', 'unavailable')".freeze
  RESULTS_AFTER = "result IN ('passed', 'failed', 'unavailable', 'pending')".freeze

  def up
    remove_check_constraint :operational_checks, name: "operational_checks_kind"
    add_check_constraint :operational_checks, KINDS_AFTER, name: "operational_checks_kind"
    remove_check_constraint :operational_checks, name: "operational_checks_result"
    add_check_constraint :operational_checks, RESULTS_AFTER, name: "operational_checks_result"
  end

  def down
    if OperationalCheck.where(check_kind: "memory_verification").exists? ||
        OperationalCheck.where(result: "pending").exists?
      raise ActiveRecord::IrreversibleMigration
    end

    remove_check_constraint :operational_checks, name: "operational_checks_kind"
    add_check_constraint :operational_checks, KINDS_BEFORE, name: "operational_checks_kind"
    remove_check_constraint :operational_checks, name: "operational_checks_result"
    add_check_constraint :operational_checks, RESULTS_BEFORE, name: "operational_checks_result"
  end
end
