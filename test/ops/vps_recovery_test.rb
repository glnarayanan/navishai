require "minitest/autorun"
require "open3"
require "shellwords"

class VpsRecoveryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SOURCE = File.join(ROOT, "ops/vps/recovery.sh")
  FIXTURE = File.join(ROOT, "test/support/vps_recovery_mock.sh")

  def run_shell(body)
    command = [ "bash", "-c", "RECOVERY_SOURCE=#{Shellwords.escape(SOURCE)}\nsource #{Shellwords.escape(FIXTURE)}\n#{body}" ]
    command.unshift("sudo", "-n") unless Process.uid.zero?
    output, status = Open3.capture2e(*command)
    assert status.success?, output
    refute_includes output, "synthetic-secret-never-print"
  end

  def test_complete_backup_has_private_checksums_and_never_restarts
    run_shell <<~'SH'
      touch "$ROOT/running"
      good_backup
      assert_stopped
      [[ "$(stat -c '%u:%a' "$ROOT/backups/good")" == 0:700 ]]
      [[ "$(find "$ROOT/backups/good" -type f ! -perm 600 | wc -l)" == 0 ]]
      (cd "$ROOT/backups/good" && sha256sum -c CHECKSUMS)
      [[ "$(head -n1 "$ROOT/log")" == stop ]]
      if tar -tf "$ROOT/backups/good/state.tar" | grep -q install.lock; then exit 1; fi
      [[ "$(stat -c %i "$VPS_STATE/install.lock")" == "$LOCK_INODE" ]]
      [[ "$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 | wc -l)" == 1 ]]
    SH
  end

  def test_destination_is_never_replaced_on_success_or_failure
    run_shell <<~'SH'
      good_backup
      before="$(sha256sum "$ROOT/backups/good/CHECKSUMS")"
      touch "$ROOT/running"
      if vps_backup "$ROOT/backups/good"; then exit 1; fi
      [[ "$(sha256sum "$ROOT/backups/good/CHECKSUMS")" == "$before" ]]
      FAIL_STEP=dump-navishai_lab_production_queue
      if vps_backup "$ROOT/backups/failed"; then exit 1; fi
      [[ ! -e "$ROOT/backups/failed" ]]
      [[ "$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 | wc -l)" == 1 ]]
      assert_stopped
    SH
  end

  def test_partial_volume_backup_cannot_publish
    run_shell <<~'SH'
      FAIL_STEP=volume-caddy_data
      if vps_backup "$ROOT/backups/failed"; then exit 1; fi
      [[ "$(find "$ROOT/backups" -mindepth 1 | wc -l)" == 0 ]]
      assert_stopped
    SH
  end

  def test_restore_changes_code_config_state_volumes_but_keeps_lock_and_stops
    run_shell <<~'SH'
      good_backup
      mkdir -p "$VPS_PREFIX/releases/$NEW"
      cp -a "$VPS_RELEASE/." "$VPS_PREFIX/releases/$NEW/"
      echo "$NEW" > "$VPS_PREFIX/releases/$NEW/SOURCE_COMMIT"
      ln -sfn "releases/$NEW" "$VPS_PREFIX/current"
      VPS_RELEASE="$VPS_PREFIX/releases/$NEW"
      echo changed > "$VPS_CONFIG/env"
      echo changed > "$VPS_STATE/bootstrap"
      echo stray > "$VPS_CONFIG/stray"
      echo changed > "$ROOT/volumes/rails_storage/value"
      vps_restore "$ROOT/backups/good"
      [[ "$(realpath "$VPS_PREFIX/current")" == "$VPS_PREFIX/releases/$OLD" ]]
      [[ "$VPS_RELEASE" == "$VPS_PREFIX/releases/$OLD" ]]
      grep -qx synthetic-secret-never-print "$VPS_CONFIG/env"
      grep -qx synthetic-bootstrap-state "$VPS_STATE/bootstrap"
      [[ ! -e "$VPS_CONFIG/stray" ]]
      grep -qx synthetic-rails_storage-old "$ROOT/volumes/rails_storage/value"
      [[ "$(stat -c %i "$VPS_STATE/install.lock")" == "$LOCK_INODE" ]]
      [[ "$(stat -c '%u:%a' "$VPS_STATE/recovery-images.yaml")" == 0:600 ]]
      jq -e '.services | keys == ["app-net","jobs","postgres","proxy","web"]' "$VPS_STATE/recovery-images.yaml"
      jq -e --arg pg "$PG_ID" --arg app "$APP_ID" --arg proxy "$PROXY_ID" --arg net "$NET_ID" \
        '.services == {postgres:{image:$pg},web:{image:$app},jobs:{image:$app},proxy:{image:$proxy},"app-net":{image:$net}}' \
        "$VPS_STATE/recovery-images.yaml"
      assert_stopped
    SH
  end

  def test_checksum_and_extra_file_rejection_precede_mutation
    run_shell <<~'SH'
      good_backup
      echo corrupt >> "$ROOT/backups/good/queue.dump"
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      if grep -qx 'compose down' "$ROOT/log"; then exit 1; fi
      rehash
      echo extra > "$ROOT/backups/good/extra"
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      if grep -qx 'compose down' "$ROOT/log"; then exit 1; fi
      assert_stopped
    SH
  end

  def test_manifest_roles_database_identity_and_volume_labels_fail_closed
    run_shell <<~'SH'
      good_backup
      cp "$ROOT/backups/good/manifest" "$ROOT/original-manifest"
      printf 'image\tunrelated\tpostgres:synthetic\t%s\n' "$PG_ID" >> "$ROOT/backups/good/manifest"
      rehash
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      cp "$ROOT/original-manifest" "$ROOT/backups/good/manifest"
      sed -i 's/navishai_setup/navishai_admin/' "$ROOT/backups/good/roles.tsv"
      rehash
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      cp "$ROOT/roles.tsv" "$ROOT/backups/good/roles.tsv"
      echo unrelated_database > "$ROOT/backups/good/primary.dump"
      rehash
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      if grep -qx 'compose down' "$ROOT/log"; then exit 1; fi
      FAIL_STEP=foreign-volume
      if vps_backup "$ROOT/backups/foreign"; then exit 1; fi
      [[ ! -e "$ROOT/backups/foreign" ]]
      assert_stopped
    SH
  end

  def test_unsafe_archive_paths_links_owners_modes_duplicates_and_controls
    run_shell <<~'SH'
      mkdir "$ROOT/tar-source"
      echo data > "$ROOT/tar-source/value"
      tar -cf "$ROOT/tar-good" -C "$ROOT/tar-source" .
      vps_recovery_tar_check "$ROOT/tar-good" private
      for transform in 's,value,../escape,' 's,value,/escape,'; do
        tar --transform="$transform" -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" value
        if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      done
      for owner in 1000 99; do
        tar --owner="$owner" -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
        if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      done
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" value value
      if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      ln -s /etc "$ROOT/tar-source/link"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" root; then exit 1; fi
      rm "$ROOT/tar-source/link"
      ln "$ROOT/tar-source/value" "$ROOT/tar-source/hardlink"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      rm "$ROOT/tar-source/hardlink"
      touch "$ROOT/tar-source/line"$'\n'"break"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      rm "$ROOT/tar-source/line"$'\n'"break"
      touch "$ROOT/tar-source/space "
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      rm "$ROOT/tar-source/space "
      chmod 644 "$ROOT/tar-source/value"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" private; then exit 1; fi
      chmod 4600 "$ROOT/tar-source/value"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" root; then exit 1; fi
    SH
  end

  def test_caddy_sticky_directory_is_scoped_and_retained_through_backup_restore
    run_shell <<~'SH'
      mkdir -p "$ROOT/tar-source/caddy"
      chmod 755 "$ROOT/tar-source"
      chmod 1777 "$ROOT/tar-source/caddy"
      echo certificate > "$ROOT/tar-source/caddy/value"
      tar -cf "$ROOT/tar-caddy" -C "$ROOT/tar-source" .
      vps_recovery_tar_check "$ROOT/tar-caddy" caddy
      for kind in root storage image; do
        if vps_recovery_tar_check "$ROOT/tar-caddy" "$kind"; then exit 1; fi
      done
      for mode in 777 3777 4777; do
        chmod "$mode" "$ROOT/tar-source/caddy"
        tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
        if vps_recovery_tar_check "$ROOT/tar-bad" caddy; then exit 1; fi
      done
      chmod 1777 "$ROOT/tar-source/caddy"
      for ownership in --owner=1000 --group=1000; do
        tar "$ownership" -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
        if vps_recovery_tar_check "$ROOT/tar-bad" caddy; then exit 1; fi
      done
      chmod 666 "$ROOT/tar-source/caddy/value"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" caddy; then exit 1; fi
      chmod 600 "$ROOT/tar-source/caddy/value"
      mkdir -m 1777 "$ROOT/tar-source/caddy/nested"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" caddy; then exit 1; fi
      rmdir "$ROOT/tar-source/caddy/nested"
      mv "$ROOT/tar-source/caddy" "$ROOT/tar-source/other"
      tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
      if vps_recovery_tar_check "$ROOT/tar-bad" caddy; then exit 1; fi
      rm -rf "$ROOT/tar-source/other"
      for node in link fifo file; do
        case "$node" in
          link) ln -s /etc "$ROOT/tar-source/caddy" ;;
          fifo) mkfifo "$ROOT/tar-source/caddy" ;;
          file) touch "$ROOT/tar-source/caddy"; chmod 1777 "$ROOT/tar-source/caddy" ;;
        esac
        tar -cf "$ROOT/tar-bad" -C "$ROOT/tar-source" .
        if vps_recovery_tar_check "$ROOT/tar-bad" caddy; then exit 1; fi
        rm "$ROOT/tar-source/caddy"
      done
      for key in caddy_data caddy_config; do
        mkdir -m 1777 "$ROOT/volumes/$key/caddy"
      done
      good_backup
      for key in caddy_data caddy_config; do chmod 755 "$ROOT/volumes/$key/caddy"; done
      vps_restore "$ROOT/backups/good"
      for key in caddy_data caddy_config; do
        [[ "$(stat -c '%u:%g:%a' "$ROOT/volumes/$key/caddy")" == 0:0:1777 ]]
      done
      assert_stopped
    SH
  end

  def test_untrusted_backup_ownership_permissions_links_and_immutable_collision
    run_shell <<~'SH'
      good_backup
      chmod 644 "$ROOT/backups/good/manifest"
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      chmod 600 "$ROOT/backups/good/manifest"
      chown 1000:1000 "$ROOT/backups/good/manifest"
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      chown 0:0 "$ROOT/backups/good/manifest"
      ln -s "$ROOT/backups/good" "$ROOT/backups/link"
      if vps_restore "$ROOT/backups/link"; then exit 1; fi
      echo unreviewed > "$VPS_RELEASE/extra-code"
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      rm "$VPS_RELEASE/extra-code"
      echo modified > "$VPS_RELEASE/code"
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      if grep -qx 'compose down' "$ROOT/log"; then exit 1; fi
      assert_stopped
    SH
  end

  def test_partial_restore_never_starts_and_keeps_original_backup
    run_shell <<~'SH'
      good_backup
      original="$(sha256sum "$ROOT/backups/good/CHECKSUMS")"
      FAIL_STEP=restore-navishai_lab_production_cache
      if vps_restore "$ROOT/backups/good"; then exit 1; fi
      grep -q 'pg_restore.*postgres' "$ROOT/log"
      [[ "$(sha256sum "$ROOT/backups/good/CHECKSUMS")" == "$original" ]]
      [[ "$(stat -c %i "$VPS_STATE/install.lock")" == "$LOCK_INODE" ]]
      [[ "$(find "$VPS_PREFIX" -maxdepth 1 -name '.recovery-*' | wc -l)" == 0 ]]
      assert_stopped
    SH
  end

  def test_shared_foreign_or_nonlocal_volumes_and_live_clients_precede_destructive_restore
    run_shell <<~'SH'
      good_backup
      for failure in foreign-owner remote-driver bind-options foreign-user forged-user foreign-client; do
        FAIL_STEP="$failure"
        if [[ "$failure" != foreign-client ]]; then
          if vps_recovery_volume rails_storage; then exit 1; fi
        fi
        if vps_restore "$ROOT/backups/good"; then exit 1; fi
        if grep -qx 'compose down' "$ROOT/log"; then exit 1; fi
        if grep -q 'pg_restore.*postgres' "$ROOT/log"; then exit 1; fi
        grep -qx synthetic-secret-never-print "$VPS_CONFIG/env"
        grep -qx synthetic-rails_storage-old "$ROOT/volumes/rails_storage/value"
        if vps_backup "$ROOT/backups/rejected"; then exit 1; fi
        [[ ! -e "$ROOT/backups/rejected" ]]
        assert_stopped
      done
    SH
  end

  def test_postgres_16_layout_still_backs_up_and_restores_its_own_files
    run_shell <<~'SH'
      mock_pg_switch 16
      good_backup
      [[ "$(tar -xOf "$ROOT/backups/good/postgres-config.tar" pg_hba.conf)" == synthetic-postgres-config-16 ]]
      echo changed > "$ROOT/volumes/lab_postgres_data/pg_hba.conf"
      vps_restore "$ROOT/backups/good"
      grep -qx synthetic-postgres-config-16 "$ROOT/volumes/lab_postgres_data/pg_hba.conf"
      grep -qx synthetic-postgres-config-18 "$ROOT/volumes/lab_postgres18_data/18/docker/pg_hba.conf"
      assert_stopped
    SH
  end

  def test_migration_moves_a_16_backup_into_18_and_leaves_the_16_volume_alone
    run_shell <<~'SH'
      mock_pg_switch 16
      good_backup
      legacy() { (cd "$ROOT/volumes/lab_postgres_data" && find . -type f -exec sha256sum {} + | sort); }
      before="$(legacy)"
      release="$(realpath "$VPS_PREFIX/current")"
      cp "$VPS_CONFIG/env" "$ROOT/env-before"
      mock_pg_switch 18
      [[ "$(vps_recovery_postgres_state)" == pending ]]
      : > "$ROOT/log"
      vps_recovery_migrate "$ROOT/backups/good"
      for database in navishai_lab_production navishai_lab_production_cache navishai_lab_production_queue navishai_lab_production_cable; do
        grep -qx restored "$ROOT/databases/$database"
      done
      for file in postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf; do
        cmp "$ROOT/volumes/lab_postgres_data/$file" "$ROOT/volumes/lab_postgres18_data/18/docker/$file"
      done
      [[ "$(legacy)" == "$before" ]]
      if grep -q 'src=navishai-reset_lab_postgres_data,' "$ROOT/log"; then exit 1; fi
      if grep -qE 'compose down|image load' "$ROOT/log"; then exit 1; fi
      [[ "$(realpath "$VPS_PREFIX/current")" == "$release" ]]
      cmp "$ROOT/env-before" "$VPS_CONFIG/env"
      [[ "$(vps_recovery_postgres_state)" == migrated ]]
      [[ "$(stat -c '%u:%a' "$VPS_STATE/postgres18-migrated")" == 0:600 ]]
      [[ "$(cat "$VPS_STATE/postgres18-migrated")" == "$(sha256sum "$ROOT/backups/good/CHECKSUMS" | cut -d' ' -f1)" ]]
      [[ "$(find "$VPS_PREFIX" -maxdepth 1 -name '.recovery-*' | wc -l)" == 0 ]]
      # Done once: a second run would overwrite live 18 data, so it refuses.
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      assert_stopped
    SH
  end

  def test_rollback_to_the_migrated_backup_reuses_the_untouched_16_volume
    run_shell <<~'SH'
      mock_pg_switch 16
      good_backup
      mock_pg_switch 18
      vps_recovery_migrate "$ROOT/backups/good"
      legacy() { (cd "$ROOT/volumes/lab_postgres_data" && find . -type f -exec sha256sum {} + | sort); }
      before="$(legacy)"
      # The restored release runs 16 again; its databases are verified, not rewritten.
      mock_pg_switch 16
      : > "$ROOT/log"
      vps_restore "$ROOT/backups/good"
      if grep -q 'pg_restore -U\|DROP DATABASE\|ALTER ROLE' "$ROOT/log"; then exit 1; fi
      if grep 'entrypoint sh' "$ROOT/log" | grep -q lab_postgres; then exit 1; fi
      grep 'entrypoint tar' "$ROOT/log" | grep -q 'src=navishai-reset_lab_postgres_data,'
      [[ "$(legacy)" == "$before" ]]
      [[ ! -e "$VPS_STATE/postgres18-migrated" ]]
      assert_stopped
    SH
  end

  def test_rollback_with_a_different_backup_rewrites_the_databases
    run_shell <<~'SH'
      mock_pg_switch 16
      good_backup
      mock_pg_switch 18
      vps_recovery_migrate "$ROOT/backups/good"
      echo 0000 > "$VPS_STATE/postgres18-migrated"
      mock_pg_switch 16
      : > "$ROOT/log"
      vps_restore "$ROOT/backups/good"
      grep -q 'pg_restore -U navishai_admin' "$ROOT/log"
      assert_stopped
    SH
  end

  def test_migration_refuses_unless_pending_before_dropping_anything
    run_shell <<~'SH'
      good_backup
      [[ "$(vps_recovery_postgres_state)" == none ]]
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      mock_pg_switch 16
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      mock_pg_switch 18
      FAIL_STEP=volume-ls
      if vps_recovery_postgres_state; then exit 1; fi
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      FAIL_STEP=
      install -m 600 /dev/null "$VPS_STATE/postgres18-migrated"
      [[ "$(vps_recovery_postgres_state)" == migrated ]]
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      rm "$VPS_STATE/postgres18-migrated"
      ln -s /dev/null "$VPS_STATE/postgres18-migrated"
      if vps_recovery_postgres_state; then exit 1; fi
      rm "$VPS_STATE/postgres18-migrated"
      touch "$ROOT/running"
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      if grep -q 'pg_restore.*postgres\|DROP DATABASE' "$ROOT/log"; then exit 1; fi
      assert_stopped
    SH
  end

  def test_partial_migration_stays_pending_and_stopped
    run_shell <<~'SH'
      mock_pg_switch 16
      good_backup
      mock_pg_switch 18
      FAIL_STEP=restore-navishai_lab_production_cache
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      [[ ! -e "$VPS_STATE/postgres18-migrated" ]]
      [[ "$(cat "$VPS_STATE/postgres18-migrating")" == "$(sha256sum "$ROOT/backups/good/CHECKSUMS" | cut -d' ' -f1)" ]]
      FAIL_STEP=
      [[ "$(vps_recovery_postgres_state)" == pending ]]
      [[ "$(find "$VPS_PREFIX" -maxdepth 1 -name '.recovery-*' | wc -l)" == 0 ]]
      assert_stopped
      vps_recovery_migrate "$ROOT/backups/good"
      [[ "$(vps_recovery_postgres_state)" == migrated ]]
      [[ ! -e "$VPS_STATE/postgres18-migrating" ]]
    SH
  end

  def test_rollback_after_a_failed_migration_also_keeps_the_16_volume
    run_shell <<~'SH'
      mock_pg_switch 16
      good_backup
      mock_pg_switch 18
      FAIL_STEP=restore-navishai_lab_production_queue
      if vps_recovery_migrate "$ROOT/backups/good"; then exit 1; fi
      FAIL_STEP=
      mock_pg_switch 16
      : > "$ROOT/log"
      vps_restore "$ROOT/backups/good"
      if grep -q 'pg_restore -U\|DROP DATABASE' "$ROOT/log"; then exit 1; fi
      [[ ! -e "$VPS_STATE/postgres18-migrating" ]]
      assert_stopped
    SH
  end

  def test_policy_gate_refuses_writers_while_16_data_awaits_migration
    run_shell <<~SH
      source #{Shellwords.escape(File.join(ROOT, "ops/vps/policy.sh"))}
      _vps_policy_postgres
      mock_pg_switch 16
      if _vps_policy_postgres 2> "$ROOT/gate"; then exit 1; fi
      grep -q 'POSTGRES_18_UPGRADE.md' "$ROOT/gate"
      : > "$ROOT/log"
      if vps_policy_check 2>/dev/null; then exit 1; fi
      if vps_policy_apply 2>/dev/null; then exit 1; fi
      if grep -q 'app-net' "$ROOT/log"; then exit 1; fi
      FAIL_STEP=volume-ls
      if _vps_policy_postgres 2>/dev/null; then exit 1; fi
      FAIL_STEP=
      install -m 600 /dev/null "$VPS_STATE/postgres18-migrated"
      _vps_policy_postgres
    SH
  end
end
