require "rails_helper"
require_relative "../support/layer_effect_boundary_scanner"

RSpec.describe "Query, Form, Admin, and rendering effect boundary" do
  ADMIN_MUTATION_EXCEPTIONS = {}.freeze

  ADMIN_OPERATION_CALLS = {
    [ "app/controllers/admin/announcements_controller.rb", :archive_announcement ] => 1,
    [ "app/controllers/admin/announcements_controller.rb", :create_announcement ] => 1,
    [ "app/controllers/admin/announcements_controller.rb", :publish_announcement ] => 1,
    [ "app/controllers/admin/announcements_controller.rb", :update_announcement ] => 1,
    [ "app/controllers/admin/contact_requests_controller.rb", :update_contact_request_status ] => 1,
    [ "app/controllers/admin/security_events_controller.rb", :update_security_event_status ] => 1
  }.freeze

  SYSTEM_OPERATION_CALLS = {
    [ "app/controllers/admin/ip_blocks_controller.rb", :execute_ip_access_operation ] => 1,
    [ "app/controllers/admin/receipt_analysis_cleanup_controller.rb", :execute_receipt_analysis_cleanup ] => 1,
    [ "app/controllers/admin/receipts_controller.rb", :execute_receipt_moderation_operation ] => 1,
    [ "app/controllers/admin/security_events_controller.rb", :execute_ip_access_operation ] => 1,
    [ "app/controllers/admin/system_settings_controller.rb", :reset_setting ] => 1,
    [ "app/controllers/admin/system_settings_controller.rb", :update_setting ] => 1,
    [ "app/controllers/admin/user_limit_overrides_controller.rb", :update_user_limit ] => 1,
    [ "app/controllers/admin/user_limit_overrides_controller.rb", :user_limit_update_confirmation_text ] => 1,
    [ "app/controllers/admin/user_operations_controller.rb", :execute_user_operation ] => 1,
    [ "app/controllers/admin/users_controller.rb", :user_limit_update_confirmation_text ] => 1
  }.freeze

  SECURITY_MUTATION_CALLS = {
    [ "app/services/system_operations/ip_access_operation_executor.rb", :manual_ip_block ] => 1,
    [ "app/services/system_operations/ip_access_operation_executor.rb", :manual_ip_unblock ] => 1,
    [ "app/services/system_operations/ip_access_operation_executor.rb", :rack_attack_ban_reset ] => 1,
    [ "app/services/system_operations/ip_access_operation_executor.rb", :record_ip_access_operation ] => 1
  }.freeze

  SERVICE_RENDER_EXCEPTIONS = [
    {
      source_path: "app/services/external_services/status_snapshot.rb",
      receiver_source: "renderer",
      method_name: :render_to_string,
      reason: "status payloadがview badge HTMLを生成する既存逆依存",
      remove_in_loop: 15
    }
  ].freeze

  before(:context) do
    @scanner = LayerEffectBoundary::Scanner.new(root: Rails.root)
  end

  let(:scanner) { @scanner }

  it "QueryとFormからDB write・enqueue・provider・audit mutationを行わない" do
    expect(scanner.layer_effects).to be_empty, scanner.layer_effects.map(&:to_h).join("\n")
  end

  it "Admin controllerの直接DB mutationをexact legacy fingerprintだけに限定する" do
    actual = scanner.admin_controller_mutations.map do |effect|
      [ effect.source_path, effect.receiver_source, effect.method_name ]
    end.tally

    expect(actual).to eq(ADMIN_MUTATION_EXCEPTIONS)
  end

  it "routine Admin mutationをAdmin::Operationsのexact facade callへ限定する" do
    actual = scanner.constant_calls("Admin::Operations", globs: "app/controllers/admin/**/*.rb").map do |effect|
      [ effect.source_path, effect.method_name ]
    end.tally

    expect(actual).to eq(ADMIN_OPERATION_CALLS)
  end

  it "high-risk Admin操作をSystemOperationsのexact facade callへ限定する" do
    actual = scanner.constant_calls("SystemOperations", globs: "app/controllers/admin/**/*.rb").map do |effect|
      [ effect.source_path, effect.method_name ]
    end.tally

    expect(actual).to eq(SYSTEM_OPERATION_CALLS)
  end

  it "Security mutationをSystemOperations childからだけ呼ぶ" do
    mutation_methods = SECURITY_MUTATION_CALLS.keys.map(&:last).uniq
    actual = scanner.constant_calls("Security", globs: "app/**/*.rb")
      .select { |effect| mutation_methods.include?(effect.method_name) }
      .map { |effect| [ effect.source_path, effect.method_name ] }
      .tally

    expect(actual).to eq(SECURITY_MUTATION_CALLS)
  end

  it "serviceのHTML renderingをexact legacy exceptionだけに限定する" do
    actual = scanner.service_render_calls.map do |effect|
      {
        source_path: effect.source_path,
        receiver_source: effect.receiver_source,
        method_name: effect.method_name
      }
    end
    expected = SERVICE_RENDER_EXCEPTIONS.map do |exception|
      exception.slice(:source_path, :receiver_source, :method_name)
    end

    expect(actual).to eq(expected)
    expect(SERVICE_RENDER_EXCEPTIONS).to all(include(reason: be_present, remove_in_loop: 15))
  end

  it "対象production sourceをPrismで解析できる" do
    formatted = scanner.analysis_issues.map { |issue| "#{issue.source_path}:#{issue.line}: #{issue.message}" }

    expect(formatted).to be_empty, formatted.join("\n")
  end
end
