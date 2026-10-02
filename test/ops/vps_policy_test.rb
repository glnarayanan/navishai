require "minitest/autorun"
require "open3"
require_relative "../../ops/edge_policy"

class VpsPolicyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  HOLDER = "a" * 64
  POSTGRES = "b" * 64
  CONTROL = "c" * 64
  EDGE = "d" * 64

  def shell(script, environment = {})
    Open3.capture2e(environment, "bash", "-eu", "-c", "source ops/vps/policy.sh; #{script}", chdir: ROOT)
  end

  def rules(family)
    output, status = shell("_vps_policy_rules #{family} 172.23.0.7")
    assert status.success?, output
    output
  end

  def inspection(holder: nil, postgres: nil, **environment)
    holder ||= [ HOLDER, "navishai-reset", "navishai-reset", "app-net", "1234", "true", "false", "navishai-reset_control", "no",
      "1000:1000", '["ALL"]', "null", '["no-new-privileges:true"]', "2", CONTROL, "172.23.0.2", "", EDGE, "172.24.0.2", "" ].join("|")
    postgres ||= [ POSTGRES, "navishai-reset", "navishai-reset", "postgres", "1235", "true", "false", "navishai-reset_control", "no", "1", CONTROL, "172.23.0.7", "" ].join("|")
    shell("source test/support/vps_policy_inspect_fixture.sh; _vps_policy_inspect",
      { "HOLDER" => HOLDER, "POSTGRES" => POSTGRES, "CONTROL" => CONTROL, "EDGE" => EDGE,
        "HOLDER_INFO" => holder, "POSTGRES_INFO" => postgres }.merge(environment.transform_keys(&:to_s)))
  end

  def test_cidrs_match_both_sources_of_truth
    source = File.read(File.join(ROOT, "app/services/evaluation_http.rb"))
    [ [ "iptables", Operations::EdgePolicy::BLOCKED_IPV4, "4" ], [ "ip6tables", Operations::EdgePolicy::BLOCKED_IPV6, "6" ] ].each do |family, cidrs, version|
      assert_equal cidrs, source[/BLOCKED_IPV#{version} = %w\[(.*?)\]/, 1].split
      cidrs.each { |cidr| assert_includes rules(family), "-d #{cidr} -j REJECT" }
    end
    assert_includes rules("ip6tables"), "! -d 2000::/3 -j REJECT"
  end

  def test_only_exact_postgres_port_dns_original_tuple_and_reply_direction_are_exempt
    ipv4 = rules("iptables")
    assert_includes ipv4, "--ctstate RELATED,ESTABLISHED --ctdir REPLY -j ACCEPT"
    assert_includes ipv4, "-d 172.23.0.7/32 -p tcp -m tcp --dport 5432 -j ACCEPT"
    %w[tcp udp].each do |protocol|
      assert_includes ipv4, "-d 127.0.0.11/32 -o lo -p #{protocol} -m conntrack --ctorigdst 127.0.0.11 --ctorigdstport 53 --ctdir ORIGINAL -j ACCEPT"
    end
    assert_includes ipv4, "-d 127.0.0.1/32 -o lo -j ACCEPT"
    refute_includes ipv4, "-d 127.0.0.0/8 -o lo -j ACCEPT"
    assert ipv4.index("--dport 5432") < ipv4.index("-d 172.16.0.0/12")
    assert_includes rules("ip6tables"), "-d ::1/128 -o lo -j ACCEPT"
    assert_equal 2, rules("ip6tables").lines.count { |line| line.include?("--icmpv6-type") }
    refute_includes rules("ip6tables"), "-p ipv6-icmp -j ACCEPT"
  end

  def test_exact_owned_control_and_edge_are_required
    output, status = inspection
    assert status.success?, output
    assert_equal "172.23.0.7", output.lines.last.strip
    [ [ "navishai-reset|navishai-reset|app-net", "foreign|navishai-reset|app-net" ],
      [ "|app-net|", "|web|" ], [ "|1234|true|", "|1|true|" ],
      [ "|true|false|", "|false|false|" ], [ "|false|navishai-reset_control|", "|true|navishai-reset_control|" ],
      [ "|no|1000:1000|", "|always|1000:1000|" ], [ '["ALL"]', "null" ],
      [ '|null|["no-new-privileges:true"]|', '|["NET_ADMIN"]|["no-new-privileges:true"]|' ],
      [ '["no-new-privileges:true"]', "null" ], [ "|2|#{CONTROL}|", "|3|#{CONTROL}|" ] ].each do |from, to|
      normal, = inspection
      holder = normal.lines.first.strip.sub(from, to)
      refute_equal normal.lines.first.strip, holder
      output, status = inspection(holder:)
      refute status.success?, output
    end
    %w[NETWORK_OWNER NETWORK_PROJECT NETWORK_NAME NETWORK_INTERNAL].each do |field|
      output, status = inspection(**{ field => "foreign" })
      refute status.success?, output
      assert_includes output, "network ownership"
    end
  end

  def test_postgres_must_be_same_project_control_only_with_valid_current_ipv4
    normal, = inspection
    pg = normal.lines[1].strip
    [ [ "|postgres|", "|app-net|" ], [ "|navishai-reset|postgres|", "|foreign|postgres|" ],
      [ "|1|#{CONTROL}|", "|2|#{CONTROL}|" ], [ CONTROL, EDGE ],
      [ "172.23.0.7", "172.23.0.7;true" ], [ "172.23.0.7", "172.23.0.999" ],
      [ "172.23.0.7", "172.23.0.02" ], [ "172.23.0.7", "127.0.0.1" ] ].each do |from, to|
      output, status = inspection(postgres: pg.sub(from, to))
      refute status.success?, output
    end
    output, status = inspection(postgres: "#{pg}|fd00::7")
    refute status.success?, output
  end

  def test_shared_namespace_and_ambiguous_container_selection_fail_before_nsenter
    %w[100 101].each do |inode|
      output, status = inspection(NAMESPACE: inode)
      refute status.success?, output
      assert_includes output, "shared/host"
    end
    output, status = inspection(HOLDER_IDS: "#{HOLDER}\n#{POSTGRES}")
    refute status.success?, output
    assert_includes output, "exactly one"
  end

  def test_check_refuses_shadowed_duplicate_missing_or_changed_chain
    base = <<~'SH'
      _vps_policy_namespace=/unused
      _vps_policy_postgres=172.23.0.7
      nsenter() {
        if [[ ${@: -1} == NAVISHAI_OUTPUT ]]; then
          _vps_policy_rules "$2" "$_vps_policy_postgres"
          [[ ${CHANGED:-} != yes ]] || echo '-A NAVISHAI_OUTPUT -j ACCEPT'
        else
          printf '%s\n' "$HOOKS"
        fi
      }
      _vps_policy_verify_family iptables
    SH
    normal = "-P OUTPUT ACCEPT\n-A OUTPUT -j NAVISHAI_OUTPUT\n-A OUTPUT -j SOME_OTHER_CHAIN"
    output, status = shell(base, "HOOKS" => normal)
    assert status.success?, output
    [ "-P OUTPUT ACCEPT", "-A OUTPUT -j ACCEPT\n-A OUTPUT -j NAVISHAI_OUTPUT",
      "-A OUTPUT -j NAVISHAI_OUTPUT\n-A OUTPUT -j NAVISHAI_OUTPUT" ].each do |hooks|
      output, status = shell(base, "HOOKS" => hooks)
      refute status.success?, output
      assert_includes output, "OUTPUT hook"
    end
    output, status = shell(base, "HOOKS" => normal, "CHANGED" => "yes")
    refute status.success?, output
    assert_includes output, "changed iptables"
  end

  def test_stale_identity_binding_cannot_pass_even_with_same_postgres_address
    script = <<~'SH'
      _vps_policy_namespace=/unused
      _vps_policy_postgres=172.23.0.7
      _vps_policy_binding=previous_identity
      installed=$(_vps_policy_rules iptables "$_vps_policy_postgres")
      _vps_policy_binding=new_identity
      nsenter() { printf '%s\n' "$installed"; }
      _vps_policy_verify_family iptables
    SH
    output, status = shell(script)
    refute status.success?, output
    assert_includes output, "changed iptables"
  end

  def test_source_is_inert_and_never_changes_host_sysctls_or_flushes_tables
    output, status = shell("declare -F vps_policy_apply vps_policy_check")
    assert status.success?, output
    assert_equal %w[vps_policy_apply vps_policy_check], output.lines.map(&:strip)
    source = File.read(File.join(ROOT, "ops/vps/policy.sh"))
    refute_match(/\bsysctl\b|--flush|--table/, source)
    assert_includes source, '"${family}-restore" --wait 5 --noflush'
  end
end
