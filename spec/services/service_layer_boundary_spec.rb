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
      public_constants: %w[
        Admin::Operations
        Admin::ReceiptAnalysisCleanupInvalidParameter
      ]
    ),
    "ai" => registry_entry("ai", "Ai", facade: "app/services/receipt_ai_enrichment_service.rb"),
    "amounts" => registry_entry("amounts", "Amounts", facade: "app/services/receipt_amount_service.rb"),
    "analysis" => registry_entry("analysis", "Analysis", facade: "app/services/analysis.rb"),
    "audit_logs" => registry_entry(
      "audit_logs",
      "AuditLogs",
      facade: "app/services/audit_logs.rb"
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
      facade: "app/services/legal_acceptances.rb"
    ),
    "legal_consents" => registry_entry(
      "legal_consents",
      "LegalConsents",
      facade: "app/services/legal_consents.rb"
    ),
    "legal_documents" => registry_entry(
      "legal_documents",
      "LegalDocuments",
      facade: "app/services/legal_documents.rb",
      public_constants: %w[LegalDocuments::Error]
    ),
    "ocr" => registry_entry("ocr", "Ocr", facade: "app/services/receipt_ocr_service.rb"),
    "receipt_analysis_profiles" => registry_entry(
      "receipt_analysis_profiles",
      "ReceiptAnalysisProfiles",
      facade: "app/services/receipt_analysis_profiles.rb"
    ),
    "receipts" => registry_entry(
      "receipts",
      "Receipts",
      public_constants: %w[
        Receipts::Editing
        Receipts::Editing::ConflictError
        Receipts::Processing
        Receipts::Uploads
        Receipts::Uploads::Result
        Receipts::Processing::AnalysisError
        Receipts::Processing::Contracts::FinalizeDecision
        Receipts::Processing::Contracts::FinalizeDecision::SCHEMA_VERSION
        Receipts::Processing::Contracts::FinalizeDecision::STRATEGIES
        Receipts::Processing::EnqueueError
        Receipts::Processing::Error
        Receipts::Processing::InvalidTransition
        Receipts::Processing::Result
        Receipts::Processing::StartResult
        Receipts::Processing::TerminalRunError
      ]
    ),
    "security" => registry_entry(
      "security",
      "Security",
      facade: "app/services/security.rb",
      public_constants: %w[Security::ValidationError]
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

  it "legacy exceptionを残さない" do
    exceptions = SERVICE_NAMESPACE_REGISTRY.values.flat_map { |entry| entry.fetch(:legacy_exceptions) }
    unused = scanner.unused_legacy_exceptions

    expect(exceptions).to be_empty
    expect(unused).to be_empty, "Unused legacy exceptions:\n#{scanner.format_legacy_exceptions(unused)}"
  end
end
