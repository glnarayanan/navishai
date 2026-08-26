require "test_helper"
require "yaml"

class DeploymentSecurityTest < ActiveSupport::TestCase
  COMPOSE_PATH = Rails.root.join("compose.yaml")
  HELM_POD_TEMPLATES = %w[web jobs runner].freeze

  test "Compose application containers drop privileges" do
    services = YAML.safe_load_file(COMPOSE_PATH, aliases: true).fetch("services")

    %w[web jobs runner supermemory].each do |name|
      service = services.fetch(name)
      assert_equal [ "ALL" ], service.fetch("cap_drop"), name
      assert_includes service.fetch("security_opt"), "no-new-privileges:true", name
    end
  end

  test "Helm workloads disable API tokens and use the runtime seccomp profile" do
    HELM_POD_TEMPLATES.each do |name|
      template = Rails.root.join("ops/helm/navishai/templates/#{name}.yaml").read
      assert_match(/^      automountServiceAccountToken: false$/, template, name)
      assert_match(/seccompProfile: \{ type: RuntimeDefault \}/, template, name)
    end
  end

  test "Helm database preparation cannot gain privileges" do
    template = Rails.root.join("ops/helm/navishai/templates/web.yaml").read
    init_container = template[/      initContainers:\n(?<body>.*?)      containers:/m, :body]

    assert_includes init_container, "allowPrivilegeEscalation: false"
    assert_includes init_container, 'capabilities: { drop: ["ALL"] }'
  end
end
