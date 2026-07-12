require "rails_helper"
require_relative "../support/receipt_workflow_boundary_scanner"

RSpec.describe "Receipt workflow dependency boundary" do
  WORKFLOW_REGISTRY = {
    "uploads" => {
      namespace: "Receipts::Uploads",
      facade_path: "app/services/receipts/uploads.rb",
      private_root: "app/services/receipts/uploads",
      allowed_workflow_facades: %w[processing],
      public_constants: []
    },
    "processing" => {
      namespace: "Receipts::Processing",
      facade_path: "app/services/receipts/processing.rb",
      private_root: "app/services/receipts/processing",
      allowed_workflow_facades: [],
      public_constants: %w[
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
    },
    "editing" => {
      namespace: "Receipts::Editing",
      facade_path: "app/services/receipts/editing.rb",
      private_root: "app/services/receipts/editing",
      allowed_workflow_facades: [],
      public_constants: []
    }
  }.freeze

  before(:context) do
    @scanner = ReceiptWorkflowBoundary::Scanner.new(root: Rails.root, registry: WORKFLOW_REGISTRY)
  end

  let(:scanner) { @scanner }

  it "workflow registryとZeitwerk catalogが一致する" do
    expect(scanner.registry_issues).to be_empty
    expect(scanner.catalog_issues).to be_empty
  end

  it "workflow間の許可依存だけを認める" do
    expect(scanner.violations).to be_empty, scanner.format_violations
  end

  it "production sourceをPrismで解析できる" do
    formatted = scanner.analysis_issues.map { |issue| "#{issue.source_path}:#{issue.line}: #{issue.message}" }

    expect(formatted).to be_empty, formatted.join("\n")
  end

  it "Processing Runsからprivate Pipelineへ逆依存しない" do
    paths = [ Rails.root.join("app/services/receipts/processing/runs.rb") ] +
      Rails.root.glob("app/services/receipts/processing/runs/**/*.rb")
    references = paths.select(&:file?).flat_map do |path|
      source_path = path.relative_path_from(Rails.root).to_s
      ServiceLayerBoundary::SourceAnalyzer.new(source_path: source_path)
        .analyze(path.read)
        .references
        .select do |reference|
          reference.constant_name.start_with?("ReceiptAnalysisPipeline", "Receipts::Processing::Pipeline")
        end
        .map { |reference| "#{source_path}:#{reference.line} -> #{reference.constant_name}" }
    end

    expect(references).to be_empty, references.join("\n")
  end

  it "Processing workflowからSystemOperationsへ逆依存しない" do
    paths = [ Rails.root.join("app/services/receipts/processing.rb") ] +
      Rails.root.glob("app/services/receipts/processing/**/*.rb")
    references = paths.select(&:file?).flat_map do |path|
      source_path = path.relative_path_from(Rails.root).to_s
      ServiceLayerBoundary::SourceAnalyzer.new(source_path: source_path)
        .analyze(path.read)
        .references
        .select { |reference| reference.constant_name.start_with?("SystemOperations") }
        .map { |reference| "#{source_path}:#{reference.line} -> #{reference.constant_name}" }
    end

    expect(references).to be_empty, references.join("\n")
  end

  it "platform serviceとAI specialistからProcessing private Pipelineへ逆依存しない" do
    paths = [ Rails.root.join("app/services/external_services.rb") ] +
      Rails.root.glob("app/services/external_services/**/*.rb") +
      Rails.root.glob("app/services/ai/**/*.rb")
    references = paths.select(&:file?).flat_map do |path|
      source_path = path.relative_path_from(Rails.root).to_s
      ServiceLayerBoundary::SourceAnalyzer.new(source_path: source_path)
        .analyze(path.read)
        .references
        .select do |reference|
          reference.constant_name.start_with?("ReceiptAnalysisPipeline", "Receipts::Processing::Pipeline")
        end
        .map { |reference| "#{source_path}:#{reference.line} -> #{reference.constant_name}" }
    end

    expect(references).to be_empty, references.join("\n")
  end

  it "Usage policyからreceipt workflowのstatus ownerへ逆依存しない" do
    paths = [ Rails.root.join("app/services/usage.rb") ] +
      Rails.root.glob("app/services/usage/**/*.rb")
    forbidden_prefixes = %w[ReceiptAnalysisPipeline ReceiptAnalysisRuns Receipts::Processing]
    references = paths.select(&:file?).flat_map do |path|
      source_path = path.relative_path_from(Rails.root).to_s
      ServiceLayerBoundary::SourceAnalyzer.new(source_path: source_path)
        .analyze(path.read)
        .references
        .select do |reference|
          forbidden_prefixes.any? { |prefix| reference.constant_name.start_with?(prefix) }
        end
        .map { |reference| "#{source_path}:#{reference.line} -> #{reference.constant_name}" }
    end

    expect(references).to be_empty, references.join("\n")
  end
end
