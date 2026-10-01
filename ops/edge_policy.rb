require "digest"
require "open3"

module Operations
  module EdgePolicy
    # Keep these aligned with EvaluationHttp's public-address boundary. This is
    # kernel enforcement for the edge bridge, not an endpoint approval registry.
    BLOCKED_IPV4 = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3].freeze
    BLOCKED_IPV6 = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20].freeze

    def self.rules(bridge, ipv6: false)
      raise "Use the exact Docker edge bridge interface." unless bridge.match?(/\Abr-[0-9a-f]{12}\z/)
      denied = ipv6 ? BLOCKED_IPV6 : BLOCKED_IPV4
      chain = "NE_#{Digest::SHA256.hexdigest([ bridge, ipv6, denied ].join('/'))[0, 12]}"
      lines = [ "*filter", ":#{chain} - [0:0]", "-A #{chain} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" ]
      # IPv6 neighbour discovery needs link-local packets even when application
      # sockets may reach only public destinations. This grants no TCP/UDP access.
      [ 135, 136 ].each { |type| lines << "-A #{chain} -p ipv6-icmp --icmpv6-type #{type} -j RETURN" } if ipv6
      lines << "-A #{chain} ! -d 2000::/3 -j REJECT" if ipv6
      denied.each { |range| lines << "-A #{chain} -d #{range} -j REJECT" }
      lines << "-A #{chain} -j RETURN"
      # INPUT covers edge-to-gateway services too; FORWARD precedes Docker's
      # same-bridge and egress ACCEPT rules. Control traffic never enters here.
      %w[INPUT FORWARD].each { |hook| lines << "-I #{hook} 1 -i #{bridge} -j #{chain}" }
      [ chain, (lines + [ "COMMIT", "" ]).join("\n") ]
    end

    def self.validate_namespace!(path)
      raise "Use an absolute existing network namespace path." unless path.start_with?("/") && File.exist?(path)
      identity = File.stat(path).ino
      raise "Refusing the shared/host network namespace." if File.stat("/proc/self/ns/net").ino == identity
      # The orb user cannot stat PID 1's namespace directly. Read its identity
      # through sudo; inability to prove isolation must fail closed.
      output, status = Open3.capture2e("sudo", "-n", "stat", "-Lc", "%i", "/proc/1/ns/net")
      raise "Cannot verify the host namespace identity." unless status.success? && output.strip.match?(/\A\d+\z/)
      raise "Refusing the shared/host network namespace." if output.strip.to_i == identity
    end

    def self.apply!(namespace, bridge)
      validate_namespace!(namespace)
      # Validate before invoking sudo or inspecting a network.
      rules(bridge)
      prefix = [ "sudo", "-n", "nsenter", "--net=#{namespace}" ]
      output, status = Open3.capture2e(*prefix, "ip", "link", "show", "dev", bridge)
      raise "Edge bridge missing in this namespace: #{output}" unless status.success? && output.include?(bridge)
      %w[iptables ip6tables].each do |family|
        output, status = Open3.capture2e(*prefix, "sysctl", "-n", "net.bridge.bridge-nf-call-#{family}")
        raise "Bridge #{family} filtering must already be enabled; no host sysctl was changed." unless status.success? && output.strip == "1"
      end
      [ false, true ].each do |ipv6|
        binary = ipv6 ? "ip6tables" : "iptables"
        chain, payload = rules(bridge, ipv6:)
        installed_rules, exists = Open3.capture2e(*prefix, binary, "-w", "5", "-S", chain)
        # Never replace or flush other rules. Refuse partial/stale policy rather
        # than call it green; workloads must remain stopped on failure.
        if exists.success?
          normalize = lambda do |line|
            line.strip.gsub("RELATED,ESTABLISHED", "ESTABLISHED,RELATED")
              .gsub(/ --reject-with \S+/, "").gsub(" -m icmp6", "")
          end
          expected = payload.lines.grep(/\A-A /).map { |line| normalize.call(line) }
          actual = installed_rules.lines.grep(/\A-A /).map { |line| normalize.call(line) }
          raise "Changed #{binary} policy; inspect the exact namespace/chain." unless actual == expected
          %w[INPUT FORWARD].each do |hook|
            hooks, installed = Open3.capture2e(*prefix, binary, "-w", "5", "-S", hook)
            first = hooks.lines.grep(/\A-A /).first&.strip
            raise "Changed #{binary} policy priority; keep workloads stopped." unless installed.success? && first == "-A #{hook} -i #{bridge} -j #{chain}"
          end
          next
        end
        output, status = Open3.capture2e(*prefix, "#{binary}-restore", "--wait", "5", "--noflush", stdin_data: payload)
        raise "Edge policy failed: #{output}" unless status.success?
      end
      puts "PASS: IPv4 special-use deny and IPv6 global-only/special-use deny on #{bridge}, inside the explicit private namespace only."
    end
  end
end
