class AddRoleToMemberships < ActiveRecord::Migration[8.1]
  ROLES = %w[owner admin manager member viewer].freeze

  def up
    add_column :memberships, :role, :string
    execute <<~SQL
      WITH ranked_memberships AS (
        SELECT id, row_number() OVER (PARTITION BY workspace_id ORDER BY created_at, id) AS workspace_rank
        FROM memberships
      )
      UPDATE memberships
      SET role = CASE WHEN ranked_memberships.workspace_rank = 1 THEN 'owner' ELSE 'member' END
      FROM ranked_memberships
      WHERE memberships.id = ranked_memberships.id
    SQL
    change_column_null :memberships, :role, false
    add_check_constraint :memberships, "role IN (#{ROLES.map { |role| quote(role) }.join(', ')})", name: "memberships_role"
    add_index :memberships, [ :workspace_id, :role ]
  end

  def down
    remove_column :memberships, :role
  end
end
