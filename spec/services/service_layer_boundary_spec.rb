require "rails_helper"
require_relative "../support/service_layer_boundary_scanner"

RSpec.describe "Service layer child implementation boundary" do
  def self.registry_entry(directory, namespace, facade: nil, public_constants: [], legacy_exceptions: [])
    private_root = "app/services/#{directory}"
    {
      namespace: namespace,
      private_root: private_root,
      internal_reference_roots: [ private_root ],
      public_facades: Array(facade),
      public_constants: public_constants,
      legacy_exceptions: legacy_exceptions
    }.freeze
  end

  SERVICE_NAMESPACE_REGISTRY = {
    "admin" => registry_entry(
      "admin",
      "Admin",
      facade: "app/services/admin.rb",
      public_constants: %w[Admin::Operations],
      legacy_exceptions: [
        {
          source_path: "app/controllers/admin/receipt_analysis_cleanup_controller.rb",
          referenced_constant: "Admin::ReceiptAnalysisCleanupPreview::InvalidParameter",
          reason: "Admin facadeがchild queryの例外型をまだ公開していない既存参照",
          remove_in_loop: 22
        }
      ]
    ),
    "ai" => registry_entry("ai", "Ai", facade: "app/services/receipt_ai_enrichment_service.rb"),
    "amounts" => registry_entry("amounts", "Amounts", facade: "app/services/receipt_amount_service.rb"),
    "analysis" => registry_entry("analysis", "Analysis", facade: "app/services/analysis.rb"),
    "audit_logs" => registry_entry(
      "audit_logs",
      "AuditLogs",
      facade: "app/services/audit_logs.rb",
      legacy_exceptions: [
        {
          source_path: "app/queries/admin/system_operations_dashboard.rb",
          referenced_constant: "AuditLogs::RetentionPolicy",
          reason: "AuditLogs facadeにretention policy参照APIが未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/services/security_events.rb",
          referenced_constant: "AuditLogs::RetentionPolicy::HIGH_RISK_ADMIN_ACTIONS",
          reason: "AuditLogs child定数へのcross-namespace既存参照",
          remove_in_loop: 22
        }
      ]
    ),
    "bot_protection" => registry_entry("bot_protection", "BotProtection", facade: "app/services/bot_protection.rb"),
    "contact_requests" => registry_entry("contact_requests", "ContactRequests", facade: "app/services/contact_requests.rb"),
    "external_services" => registry_entry(
      "external_services",
      "ExternalServices",
      facade: "app/services/external_services.rb",
      public_constants: %w[
        ExternalServices::DebugSwitchNotAvailableError
        ExternalServices::RuntimeConfigUnavailableError
      ]
    ),
    "legal_acceptances" => registry_entry(
      "legal_acceptances",
      "LegalAcceptances",
      legacy_exceptions: [
        {
          source_path: "app/controllers/legal_consents_controller.rb",
          referenced_constant: "LegalAcceptances::Recorder",
          reason: "LegalAcceptances親facade未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/controllers/users/registrations_controller.rb",
          referenced_constant: "LegalAcceptances::Recorder",
          reason: "LegalAcceptances親facade未整備の既存参照",
          remove_in_loop: 22
        }
      ]
    ),
    "legal_consents" => registry_entry(
      "legal_consents",
      "LegalConsents",
      legacy_exceptions: [
        {
          source_path: "app/controllers/application_controller.rb",
          referenced_constant: "LegalConsents::Requirement",
          reason: "LegalConsents親facade未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/controllers/legal_consents_controller.rb",
          referenced_constant: "LegalConsents::Requirement",
          reason: "LegalConsents親facade未整備の既存参照",
          remove_in_loop: 22
        }
      ]
    ),
    "legal_documents" => registry_entry(
      "legal_documents",
      "LegalDocuments",
      legacy_exceptions: [
        {
          source_path: "app/controllers/application_controller.rb",
          referenced_constant: "LegalDocuments::CurrentStatus",
          reason: "LegalDocuments親facade未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/controllers/legal_controller.rb",
          referenced_constant: "LegalDocuments::Repository",
          reason: "LegalDocuments親facade未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/controllers/legal_controller.rb",
          referenced_constant: "LegalDocuments::ValidationError",
          reason: "LegalDocuments child定義のdomain errorへの既存直接参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/queries/admin/dashboard.rb",
          referenced_constant: "LegalDocuments::CurrentStatus",
          reason: "LegalDocuments親facade未整備のcross-namespace既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/services/production_legal_documents_validator.rb",
          referenced_constant: "LegalDocuments::Error",
          reason: "専用validatorがLegalDocuments child errorを参照する既存経路",
          remove_in_loop: 22
        },
        {
          source_path: "app/services/production_legal_documents_validator.rb",
          referenced_constant: "LegalDocuments::Verifier",
          reason: "専用validatorがLegalDocuments child verifierを参照する既存経路",
          remove_in_loop: 22
        }
      ]
    ),
    "ocr" => registry_entry("ocr", "Ocr", facade: "app/services/receipt_ocr_service.rb"),
    "receipt_analysis_pipeline" => registry_entry(
      "receipt_analysis_pipeline",
      "ReceiptAnalysisPipeline",
      facade: "app/services/receipt_analysis_pipeline.rb",
      public_constants: %w[
        ReceiptAnalysisPipeline::FINALIZE_DECISION_SCHEMA_VERSION
        ReceiptAnalysisPipeline::FINALIZE_STRATEGIES
      ]
    ),
    "receipt_analysis_profiles" => registry_entry(
      "receipt_analysis_profiles",
      "ReceiptAnalysisProfiles",
      facade: "app/services/receipt_analysis_profiles.rb"
    ),
    "receipt_analysis_runs" => registry_entry(
      "receipt_analysis_runs",
      "ReceiptAnalysisRuns",
      facade: "app/services/receipt_analysis_runs.rb",
      public_constants: %w[
        ReceiptAnalysisRuns::EnqueueError
        ReceiptAnalysisRuns::TerminalRunError
      ]
    ),
    "recify" => registry_entry(
      "recify",
      "Recify",
      legacy_exceptions: [
        {
          source_path: "app/services/security_events/metadata_sanitizer.rb",
          referenced_constant: "Recify::ActiveStorageLogRedactor",
          reason: "shared redactorの親facade未整備によるcross-namespace既存参照",
          remove_in_loop: 22
        }
      ]
    ),
    "security" => registry_entry(
      "security",
      "Security",
      facade: "app/services/security.rb",
      public_constants: %w[Security::ValidationError],
      legacy_exceptions: [
        {
          source_path: "app/models/security_ip_action.rb",
          referenced_constant: "Security::IpAddress",
          reason: "Security facadeにIP正規化APIが未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/models/security_ip_block.rb",
          referenced_constant: "Security::IpAddress",
          reason: "Security facadeにIP検証APIが未整備の既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/queries/admin/ip_actions_query.rb",
          referenced_constant: "Security::IpAddress",
          reason: "Security facadeにIP正規化APIが未整備のcross-namespace既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/queries/admin/ip_blocks_query.rb",
          referenced_constant: "Security::IpAddress",
          reason: "Security facadeにIP正規化APIが未整備のcross-namespace既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/queries/admin/ip_blocks_query.rb",
          referenced_constant: "Security::RackAttackBanRegistry",
          reason: "Security facadeにban診断APIが未整備のcross-namespace既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/services/system_operations/ip_access_operation_executor.rb",
          referenced_constant: "Security::IpAddress",
          reason: "Security facadeにIP正規化APIが未整備のcross-namespace既存参照",
          remove_in_loop: 22
        },
        {
          source_path: "app/services/system_operations/ip_access_operation_executor.rb",
          referenced_constant: "Security::RackAttackBanResetter::DEFAULT_TARGET",
          reason: "Security child実装定数へのcross-namespace既存参照",
          remove_in_loop: 22
        }
      ]
    ),
    "security_events" => registry_entry("security_events", "SecurityEvents", facade: "app/services/security_events.rb"),
    "storage" => registry_entry("storage", "Storage", facade: "app/services/storage.rb"),
    "system_operations" => registry_entry("system_operations", "SystemOperations", facade: "app/services/system_operations.rb"),
    "system_settings" => registry_entry(
      "system_settings",
      "SystemSettings",
      facade: "app/services/system_settings.rb",
      public_constants: %w[
        SystemSettings::AMOUNT_LIMIT_DEFAULT
        SystemSettings::AMOUNT_LIMIT_KEYS
        SystemSettings::EXTERNAL_SERVICE_RUNTIME_TUNING_KEYS
        SystemSettings::OCR_RAW_RESPONSE_MAX_BYTES_KEY
        SystemSettings::OCR_RAW_RESPONSE_RETENTION_KEY
        SystemSettings::SETTING_DEPENDENCY_LOCK_GROUPS
        SystemSettings::UnknownKeyError
        SystemSettings::ValidationError
      ]
    ),
    "two_factor" => registry_entry(
      "two_factor",
      "TwoFactor",
      facade: "app/services/two_factor.rb",
      public_constants: %w[
        TwoFactor::SetupMaterial
        TwoFactor::VerificationError
      ]
    ),
    "usage" => registry_entry(
      "usage",
      "Usage",
      facade: "app/services/usage.rb",
      public_constants: %w[Usage::LimitExceeded]
    ),
    "user_sessions" => registry_entry("user_sessions", "UserSessions", facade: "app/services/user_sessions.rb"),
    "users" => registry_entry("users", "Users", facade: "app/services/users.rb")
  }.freeze

  before(:context) do
    @scanner = ServiceLayerBoundary::Scanner.new(
      root: Rails.root,
      registry: SERVICE_NAMESPACE_REGISTRY,
      constant_path_resolver: ->(path) { Rails.autoloaders.main.cpath_expected_at(path) }
    )
  end

  let(:scanner) { @scanner }

  it "app/services直下の全namespaceをregistryへ明示登録する" do
    expect(scanner.registry_issues).to be_empty, scanner.registry_issues.join("\n")
  end

  it "Zeitwerkの期待定数とservice childの実定義を一致させる" do
    expect(scanner.catalog_issues).to be_empty, scanner.catalog_issues.join("\n")
  end

  it "production scan対象をPrismで解析できる" do
    formatted = scanner.analysis_issues.map do |issue|
      "#{issue.source_path}:#{issue.line}: #{issue.message}"
    end
    expect(formatted).to be_empty, formatted.join("\n")
  end

  it "facadeと同一private root以外からchild実装を直接参照しない" do
    expect(scanner.violations).to be_empty, scanner.format_violations
  end

  it "legacy exceptionをsource pathとconstantの完全一致で利用し続ける" do
    unused = scanner.unused_legacy_exceptions
    expect(unused).to be_empty, "Unused legacy exceptions:\n#{scanner.format_legacy_exceptions(unused)}"
  end
end
