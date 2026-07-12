require "rails_helper"
require "fileutils"
require "tmpdir"
require_relative "../support/receipt_workflow_boundary_scanner"

RSpec.describe ReceiptWorkflowBoundary::Scanner do
  REGISTRY = {
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
      public_constants: [ "Receipts::Processing::Error" ]
    },
    "editing" => {
      namespace: "Receipts::Editing",
      facade_path: "app/services/receipts/editing.rb",
      private_root: "app/services/receipts/editing",
      allowed_workflow_facades: [],
      public_constants: []
    }
  }.freeze

  around do |example|
    Dir.mktmpdir("receipt-workflow-boundary") do |directory|
      @root = Pathname(directory)
      write_source("app/services/receipts/uploads.rb", "module Receipts::Uploads; end\n")
      write_source("app/services/receipts/processing.rb", <<~RUBY)
        module Receipts::Processing
          Error = Class.new(StandardError)
        end
      RUBY
      write_source("app/services/receipts/editing.rb", "module Receipts::Editing; end\n")
      write_source("app/services/receipts/uploads/batch.rb", "class Receipts::Uploads::Batch; end\n")
      write_source("app/services/receipts/processing/runner.rb", "class Receipts::Processing::Runner; end\n")
      write_source("app/services/receipts/editing/change_set.rb", "class Receipts::Editing::ChangeSet; end\n")
      example.run
    end
  end

  let(:scanner) { described_class.new(root: @root, registry: REGISTRY) }

  it "同一workflow内部とUploadsからProcessing facadeへの依存を許可する" do
    write_source("app/services/receipts/uploads/dispatcher.rb", <<~RUBY)
      class Receipts::Uploads::Dispatcher
        def call
          Receipts::Uploads::Batch.new
          Receipts::Processing.call
          Receipts::Processing::Error
        end
      end
    RUBY

    expect(scanner.violations).to be_empty, scanner.format_violations
  end

  it "別workflowのprivate child直接参照を検知する" do
    write_source("app/services/receipts/uploads/dispatcher.rb", <<~RUBY)
      class Receipts::Uploads::Dispatcher
        def call
          Receipts::Processing::Runner.new
        end
      end
    RUBY

    expect(scanner.violations.map(&:referenced_constant)).to eq([ "Receipts::Processing::Runner" ])
    expect(scanner.violations.first.rule).to eq(:private_implementation)
  end

  it "ProcessingからEditing facadeへの逆依存を検知する" do
    write_source("app/services/receipts/processing/runner.rb", <<~RUBY)
      class Receipts::Processing::Runner
        def call
          Receipts::Editing.call
        end
      end
    RUBY

    expect(scanner.violations.map(&:rule)).to include(:forbidden_workflow_dependency)
  end

  it "専門領域からReceipts workflowへの逆依存を検知する" do
    write_source("app/services/analysis/finalizer.rb", <<~RUBY)
      class Analysis::Finalizer
        def call
          Receipts::Processing.call
        end
      end
    RUBY

    violation = scanner.violations.find { |entry| entry.source_path == "app/services/analysis/finalizer.rb" }

    expect(violation&.rule).to eq(:specialist_reverse_dependency)
  end

  it "外部callerはfacadeと明示public constantだけを参照できる" do
    write_source("app/controllers/receipts_controller.rb", <<~RUBY)
      class ReceiptsController
        def create
          Receipts::Processing.call
          Receipts::Processing::Error
          Receipts::Processing::Runner.new
        end
      end
    RUBY

    expect(scanner.violations.map(&:referenced_constant)).to eq([ "Receipts::Processing::Runner" ])
    expect(scanner.violations.first.rule).to eq(:private_implementation)
  end

  it "commentsとstrings内のconstant名を参照として扱わない" do
    write_source("app/controllers/receipts_controller.rb", <<~RUBY)
      class ReceiptsController
        # Receipts::Processing::Runner
        LABEL = "Receipts::Editing::ChangeSet"
      end
    RUBY

    expect(scanner.violations).to be_empty
  end

  it "新規workflow rootのregistry未登録を検知する" do
    write_source("app/services/receipts/reporting.rb", "module Receipts::Reporting; end\n")

    expect(scanner.registry_issues).to include("unregistered receipt workflow root: reporting")
  end

  it "新しいprivate childを手動registryなしでcatalogとscanへ追加する" do
    write_source("app/services/receipts/processing/contracts/finalize_decision.rb", <<~RUBY)
      class Receipts::Processing::Contracts::FinalizeDecision; end
    RUBY
    write_source("app/controllers/receipts_controller.rb", <<~RUBY)
      class ReceiptsController
        FinalizeDecision = Receipts::Processing::Contracts::FinalizeDecision
      end
    RUBY

    expect(scanner.catalog_issues).to be_empty
    expect(scanner.private_constant_paths).to include(
      "app/services/receipts/processing/contracts/finalize_decision.rb" => [
        "processing",
        "Receipts::Processing::Contracts::FinalizeDecision"
      ]
    )
    expect(scanner.violations.map(&:referenced_constant)).to include(
      "Receipts::Processing::Contracts::FinalizeDecision"
    )
  end

  private

  def write_source(path, source)
    absolute_path = @root.join(path)
    FileUtils.mkdir_p(absolute_path.dirname)
    absolute_path.write(source)
  end
end
