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
      public_constants: []
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
end
