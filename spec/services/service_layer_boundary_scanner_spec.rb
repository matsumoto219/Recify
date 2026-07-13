require "rails_helper"
require "fileutils"
require "tmpdir"
require_relative "../support/service_layer_boundary_scanner"

RSpec.describe ServiceLayerBoundary::Scanner do
  ANALYSIS_FACADE = <<~RUBY.freeze
    module Analysis
      def self.call
        PrivateWorker.call
      end
    end
  RUBY

  PRIVATE_WORKER = <<~RUBY.freeze
    module Analysis
      class PrivateWorker
        def self.call; end
      end
    end
  RUBY

  def registry_entry(directory, namespace, facade: nil, public_constants: [], legacy_exceptions: [])
    private_root = "app/services/#{directory}"
    {
      namespace: namespace,
      private_root: private_root,
      internal_reference_roots: [ private_root ],
      public_facades: Array(facade),
      public_constants: public_constants,
      legacy_exceptions: legacy_exceptions
    }
  end

  def analysis_registry(public_constants: [], legacy_exceptions: [])
    {
      "analysis" => registry_entry(
        "analysis",
        "Analysis",
        facade: "app/services/analysis.rb",
        public_constants: public_constants,
        legacy_exceptions: legacy_exceptions
      )
    }
  end

  def base_files
    {
      "app/services/analysis.rb" => ANALYSIS_FACADE,
      "app/services/analysis/private_worker.rb" => PRIVATE_WORKER
    }
  end

  def with_scanner(files: {}, registry: analysis_registry)
    Dir.mktmpdir("service-layer-boundary-", Rails.root.join("tmp").to_s) do |directory|
      root = Pathname(directory)
      base_files.merge(files).each do |relative_path, source|
        path = root.join(relative_path)
        FileUtils.mkdir_p(path.dirname)
        path.write(source)
      end

      yield described_class.new(root: root, registry: registry)
    end
  end

  it "controllerからprivate childへの直接参照を検知する" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~RUBY
          class ReportsController
            def show
              Analysis::PrivateWorker.call
            end
          end
        RUBY
      }
    ) do |scanner|
      violation = scanner.violations.sole
      expect(violation.to_h).to include(
        source_path: "app/controllers/reports_controller.rb",
        referenced_constant: "Analysis::PrivateWorker",
        private_owner: "analysis"
      )
    end
  end

  it "静的文字列のdynamic constant lookupでprivate childを隠せない" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~RUBY
          class ReportsController
            def show
              Object.const_get("Analysis::PrivateWorker").call
              "Analysis::PrivateWorker".safe_constantize.call
            end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations.map(&:referenced_constant)).to contain_exactly(
        "Analysis::PrivateWorker",
        "Analysis::PrivateWorker"
      )
    end
  end

  it "private childをlocal variableへ代入してもconstant参照を検知する" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~RUBY
          class ReportsController
            def show
              worker = Analysis::PrivateWorker
              worker.call
            end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations.map(&:referenced_constant)).to eq([ "Analysis::PrivateWorker" ])
    end
  end

  it "別service namespaceからprivate childへの直接参照を検知する" do
    registry = analysis_registry.merge(
      "admin" => registry_entry("admin", "Admin")
    )
    with_scanner(
      registry: registry,
      files: {
        "app/services/admin/dashboard.rb" => <<~RUBY
          module Admin
            class Dashboard
              def call
                Analysis::PrivateWorker.call
              end
            end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations.map(&:referenced_constant)).to eq([ "Analysis::PrivateWorker" ])
    end
  end

  it "qualified constantもlexical namespaceを先に解決する" do
    registry = analysis_registry.merge(
      "outer" => registry_entry("outer", "Outer")
    )
    with_scanner(
      registry: registry,
      files: {
        "app/services/outer/analysis/private_worker.rb" => <<~RUBY,
          module Outer
            module Analysis
              class PrivateWorker; end
            end
          end
        RUBY
        "app/controllers/reports_controller.rb" => <<~RUBY
          module Outer
            Analysis::PrivateWorker.call
          end
        RUBY
      }
    ) do |scanner|
      violation = scanner.violations.sole
      expect(violation.to_h).to include(
        referenced_constant: "Outer::Analysis::PrivateWorker",
        private_owner: "outer"
      )
    end
  end

  it "同一private root内部のchild参照を許可する" do
    with_scanner(
      files: {
        "app/services/analysis/coordinator.rb" => <<~RUBY
          module Analysis
            class Coordinator
              def call
                PrivateWorker.call
              end
            end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations).to be_empty
    end
  end

  it "lexical namespace内で省略されたchild constantを解決する" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~RUBY
          module Analysis
            PrivateWorker.call
          end
        RUBY
      }
    ) do |scanner|
      violation = scanner.violations.sole
      expect(violation.to_h).to include(
        source_path: "app/controllers/reports_controller.rb",
        referenced_constant: "Analysis::PrivateWorker"
      )
    end
  end

  it "public facadeからのchild参照とcallerからのfacade参照を許可する" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~RUBY
          class ReportsController
            def show
              Analysis.call
            end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations).to be_empty
    end
  end

  it "public facadeをapp/services直下以外のpathへ登録させない" do
    registry = {
      "analysis" => registry_entry(
        "analysis",
        "Analysis",
        facade: "app/controllers/reports_controller.rb"
      )
    }
    with_scanner(
      registry: registry,
      files: {
        "app/controllers/reports_controller.rb" => "Analysis::PrivateWorker.call\n"
      }
    ) do |scanner|
      expect(scanner.registry_issues).to include(
        "analysis: public facade must be an exact app/services root file: app/controllers/reports_controller.rb"
      )
    end
  end

  it "ErrorやResultは明示したpublic constantだけを許可する" do
    with_scanner(
      registry: analysis_registry(public_constants: [ "Analysis::Result" ]),
      files: {
        "app/services/analysis/result.rb" => <<~RUBY,
          module Analysis
            Result = Data.define(:value)
          end
        RUBY
        "app/services/analysis/error.rb" => <<~RUBY,
          module Analysis
            Error = Class.new(StandardError)
          end
        RUBY
        "app/controllers/reports_controller.rb" => <<~RUBY
          class ReportsController
            def show
              [Analysis::Result.new(1), Analysis::Error]
            end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations.map(&:referenced_constant)).to eq([ "Analysis::Error" ])
    end
  end

  it "comment内のconstant名を参照として扱わない" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~RUBY
          class ReportsController
            # Analysis::PrivateWorker is intentionally named in documentation.
            def show; end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations).to be_empty
    end
  end

  it "stringとsymbol内のconstant名を参照として扱わない" do
    with_scanner(
      files: {
        "app/controllers/reports_controller.rb" => <<~'RUBY'
          class ReportsController
            TEXT = "Analysis::PrivateWorker"
            LABEL = :"Analysis::PrivateWorker"
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.violations).to be_empty
    end
  end

  it "source pathとconstantが一致するlegacy exceptionだけを許可する" do
    exception = {
      source_path: "app/controllers/reports_controller.rb",
      referenced_constant: "Analysis::PrivateWorker",
      reason: "facade未整備の既存参照",
      remove_in_loop: 22
    }
    with_scanner(
      registry: analysis_registry(legacy_exceptions: [ exception ]),
      files: {
        "app/controllers/reports_controller.rb" => "Analysis::PrivateWorker.call\n"
      }
    ) do |scanner|
      expect(scanner.violations).to be_empty
      expect(scanner.unused_legacy_exceptions).to be_empty
    end
  end

  it "同じconstantでも別source pathへlegacy exceptionを拡大しない" do
    exception = {
      source_path: "app/controllers/reports_controller.rb",
      referenced_constant: "Analysis::PrivateWorker",
      reason: "facade未整備の既存参照",
      remove_in_loop: 22
    }
    with_scanner(
      registry: analysis_registry(legacy_exceptions: [ exception ]),
      files: {
        "app/controllers/reports_controller.rb" => "Analysis::PrivateWorker.call\n",
        "app/controllers/exports_controller.rb" => "Analysis::PrivateWorker.call\n"
      }
    ) do |scanner|
      expect(scanner.violations.map(&:source_path)).to eq([ "app/controllers/exports_controller.rb" ])
    end
  end

  it "malformed legacy exceptionを例外送出せず読みやすく報告する" do
    malformed = {
      source_path: "app/controllers/reports_controller.rb",
      referenced_constant: nil,
      reason: "壊れたfixture",
      remove_in_loop: 22
    }
    with_scanner(
      registry: analysis_registry(legacy_exceptions: [ malformed ]),
      files: {
        "app/controllers/reports_controller.rb" => "Analysis.call\n"
      }
    ) do |scanner|
      expect(scanner.catalog_issues).to include(
        "legacy exception must use an exact referenced_constant: nil"
      )
    end
  end

  it "新しいservice subdirectoryのregistry登録漏れを検知する" do
    with_scanner(
      files: {
        "app/services/new_area/worker.rb" => <<~RUBY
          module NewArea
            class Worker; end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.unregistered_service_directories).to eq([ "new_area" ])
      expect(scanner.registry_issues).to include("unregistered service directory: new_area")
    end
  end

  it "将来のapp/queriesとapp/formsを自動的にscan対象へ含める" do
    with_scanner(
      files: {
        "app/queries/report_query.rb" => "Analysis::PrivateWorker.call\n",
        "app/forms/report_form.rb" => "Analysis::PrivateWorker.call\n"
      }
    ) do |scanner|
      target_paths = scanner.target_files.map { |path| path.relative_path_from(scanner.root).to_s }
      expect(target_paths).to include("app/queries/report_query.rb", "app/forms/report_form.rb")
      expect(scanner.violations.map(&:source_path)).to contain_exactly(
        "app/queries/report_query.rb",
        "app/forms/report_form.rb"
      )
    end
  end

  it "configとlibとRake taskをscan対象へ含める" do
    with_scanner(
      files: {
        "config/initializers/private_worker.rb" => "Analysis::PrivateWorker.call\n",
        "lib/report_export.rb" => "Analysis::PrivateWorker.call\n",
        "lib/tasks/reports.rake" => <<~RAKE
          task :report do
            Analysis::PrivateWorker.call
          end
        RAKE
      }
    ) do |scanner|
      target_paths = scanner.target_files.map { |path| path.relative_path_from(scanner.root).to_s }

      aggregate_failures do
        expect(target_paths).to include(
          "config/initializers/private_worker.rb",
          "lib/report_export.rb",
          "lib/tasks/reports.rake"
        )
        expect(scanner.violations.map(&:source_path)).to contain_exactly(
          "config/initializers/private_worker.rb",
          "lib/report_export.rb",
          "lib/tasks/reports.rake"
        )
      end
    end
  end

  it "新しいprivate child fileを手動constant登録なしで検査する" do
    with_scanner(
      files: {
        "app/services/analysis/new_worker.rb" => <<~RUBY,
          module Analysis
            class NewWorker; end
          end
        RUBY
        "app/controllers/reports_controller.rb" => "Analysis::NewWorker.new\n"
      }
    ) do |scanner|
      expect(scanner.private_constant_paths).to include(
        "app/services/analysis/new_worker.rb" => "Analysis::NewWorker"
      )
      expect(scanner.violations.map(&:referenced_constant)).to include("Analysis::NewWorker")
    end
  end

  it "ERB内のprivate child参照をRails template構文のまま検知する" do
    with_scanner(
      files: {
        "app/views/reports/show.html.erb" => <<~ERB
          <%# Analysis::PrivateWorker is documentation only. %>
          <% constant_name = "Analysis::PrivateWorker" %>
          <%= tag.div do %>
            <%= Analysis::PrivateWorker.call %>
          <% end %>
        ERB
      }
    ) do |scanner|
      violation = scanner.violations.sole
      expect(violation.to_h).to include(
        source_path: "app/views/reports/show.html.erb",
        referenced_constant: "Analysis::PrivateWorker"
      )
      expect(scanner.analysis_issues).to be_empty
    end
  end

  it "Zeitwerkの期待constantとchild fileの定義不一致を検知する" do
    with_scanner(
      files: {
        "app/services/analysis/mismatched.rb" => <<~RUBY
          module Analysis
            class DifferentName; end
          end
        RUBY
      }
    ) do |scanner|
      expect(scanner.catalog_issues).to include(
        "app/services/analysis/mismatched.rb: expected Analysis::Mismatched, defined Analysis, Analysis::DifferentName"
      )
    end
  end


  it "private child classを外部pathからreopenする参照を検知する" do
    with_scanner(
      files: {
        "app/controllers/private_worker_patch.rb" => <<~RUBY
          class Analysis::PrivateWorker
            def patched; end
          end
        RUBY
      }
    ) do |scanner|
      violation = scanner.violations.sole
      expect(violation.to_h).to include(
        source_path: "app/controllers/private_worker_patch.rb",
        referenced_constant: "Analysis::PrivateWorker"
      )
    end
  end
end
