class AddAttachmentScannerCheckKind < ActiveRecord::Migration[8.1]
  KINDS_BEFORE = "check_kind IN ('archive_verification', 'backup_verification', 'restore_rehearsal', 'upgrade_preflight')".freeze
  KINDS_AFTER = "check_kind IN ('archive_verification', 'attachment_scanner', 'backup_verification', 'restore_rehearsal', 'upgrade_preflight')".freeze

  def up
    remove_check_constraint :operational_checks, name: "operational_checks_kind"
    add_check_constraint :operational_checks, KINDS_AFTER, name: "operational_checks_kind"
  end

  def down
    raise ActiveRecord::IrreversibleMigration if OperationalCheck.where(check_kind: "attachment_scanner").exists?

    remove_check_constraint :operational_checks, name: "operational_checks_kind"
    add_check_constraint :operational_checks, KINDS_BEFORE, name: "operational_checks_kind"
  end
end
