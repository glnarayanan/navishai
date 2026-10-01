require "minitest/autorun"
require "ipaddr"
require_relative "../../ops/edge_policy"

class EdgePolicyTest < Minitest::Test
  def test_rejects_shared_namespace_before_any_firewall_command
    error = assert_raises(RuntimeError) { Operations::EdgePolicy.apply!("/proc/self/ns/net", "br-0123456789ab") }
    assert_includes error.message, "shared/host"
    assert_raises(RuntimeError) { Operations::EdgePolicy.validate_namespace!("relative/netns") }
  end

  def test_only_accepts_a_docker_bridge_not_a_shell_or_wildcard
    [ "eth0", "br-+", "br-0123456789ab;true", "br-0123456789ab\n" ].each do |bridge|
      assert_raises(RuntimeError) { Operations::EdgePolicy.rules(bridge) }
    end
  end

  def test_ipv4_covers_every_application_denied_range_without_blocking_control
    source = File.read(File.expand_path("../../app/services/evaluation_http.rb", __dir__))
    expected = source[/BLOCKED_IPV4 = %w\[(.*?)\]/, 1].split
    assert_equal expected, Operations::EdgePolicy::BLOCKED_IPV4
    chain, rules = Operations::EdgePolicy.rules("br-0123456789ab")
    expected.each { |range| assert_includes rules, "-A #{chain} -d #{range} -j REJECT" }
    assert_includes rules, "-I INPUT 1 -i br-0123456789ab -j #{chain}"
    assert_includes rules, "-I FORWARD 1 -i br-0123456789ab -j #{chain}"
    refute_includes rules, "OUTPUT"
    refute_includes rules, "-F"
    assert rules.index("ESTABLISHED,RELATED") < rules.index("-d 0.0.0.0/8")
    %w[10.4.5.6 100.64.1.2 169.254.169.254 172.30.2.1 198.19.2.3 240.1.2.3].each do |address|
      assert expected.any? { |range| IPAddr.new(range).include?(address) }
    end
    refute expected.any? { |range| IPAddr.new(range).include?("93.184.216.34") }
  end

  def test_ipv6_denies_mapped_private_and_non_global_and_special_global_addresses
    source = File.read(File.expand_path("../../app/services/evaluation_http.rb", __dir__))
    assert_equal source[/BLOCKED_IPV6 = %w\[(.*?)\]/, 1].split, Operations::EdgePolicy::BLOCKED_IPV6
    chain, rules = Operations::EdgePolicy.rules("br-0123456789ab", ipv6: true)
    [ 135, 136 ].each { |type| assert_includes rules, "-A #{chain} -p ipv6-icmp --icmpv6-type #{type} -j RETURN" }
    refute_includes rules, "-p ipv6-icmp -j RETURN"
    assert_includes rules, "-A #{chain} ! -d 2000::/3 -j REJECT"
    %w[::1 ::ffff:10.1.2.3 fd00::1 fe80::1].each { |ip| refute IPAddr.new("2000::/3").include?(ip) }
    %w[2001::1 2001:db8::1 2002::1 3fff::1].each do |ip|
      assert Operations::EdgePolicy::BLOCKED_IPV6.any? { |range| IPAddr.new(range).include?(ip) }
    end
    assert_includes rules, "-A #{chain} -d 2001:db8::/32 -j REJECT"
    refute_equal chain, Operations::EdgePolicy.rules("br-0123456789ab").first
  end
end
