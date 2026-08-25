require "test_helper"
require Rails.root.join("db/migrate/20260825220000_upgrade_vector_extension")

class UpgradeVectorExtensionTest < ActiveSupport::TestCase
  test "updates the previous supported vector extension" do
    statements = []
    migration = migration_for("0.8.1", statements: statements)

    migration.up

    assert_equal [ "ALTER EXTENSION vector UPDATE TO '0.8.6'" ], statements
  end

  test "leaves the target vector extension unchanged" do
    statements = []
    migration = migration_for("0.8.6", statements: statements)

    migration.up

    assert_empty statements
  end

  test "rejects an unsupported vector extension" do
    migration = migration_for("0.7.4")

    error = assert_raises(ActiveRecord::MigrationError) { migration.up }

    assert_includes error.message, "Unsupported pgvector version 0.7.4"
  end

  test "requires backup restore for rollback" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) { UpgradeVectorExtension.new.down }

    assert_includes error.message, "restore the verified pre-upgrade backup"
  end

  private

  def migration_for(version, statements: [])
    UpgradeVectorExtension.new.tap do |migration|
      migration.define_singleton_method(:select_value) { |_query| version }
      migration.define_singleton_method(:execute) { |statement| statements << statement }
    end
  end
end
