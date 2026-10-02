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
end
