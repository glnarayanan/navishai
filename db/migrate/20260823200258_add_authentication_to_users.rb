require "bcrypt"
require "securerandom"

class AddAuthenticationToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :password_digest, :string
    reversible do |direction|
      direction.up do
        unavailable_password = BCrypt::Password.create(SecureRandom.hex(32)).to_s
        execute "UPDATE users SET password_digest = #{quote(unavailable_password)} WHERE password_digest IS NULL"
      end
    end
    change_column_null :users, :password_digest, false
    add_column :users, :verified_at, :datetime
    add_column :users, :break_glass, :boolean, null: false, default: false

    add_index :users, :break_glass, unique: true, where: "break_glass", name: "index_users_on_unique_break_glass"
  end
end
