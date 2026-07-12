require "rails_helper"
require "fileutils"
require "tmpdir"
require_relative "../support/application_structure_boundary_scanner"

RSpec.describe ApplicationStructureBoundary::Scanner do
  def registry_entry(external_methods: [])
    {
      constant: "Analysis",
      role: :public_facade,
      owner: "test facade",
      external_methods: external_methods,
      declared_singleton_methods: [],
      declared_instance_methods: [],
      constructible: false,
      remove_in_loop: nil
    }
  end

  def with_scanner(files:, registry: { "analysis.rb" => registry_entry })
    Dir.mktmpdir("application-structure-boundary-", Rails.root.join("tmp").to_s) do |directory|
      root = Pathname(directory)
      files.each do |relative_path, source|
        path = root.join(relative_path)
        FileUtils.mkdir_p(path.dirname)
        path.write(source)
      end

      yield described_class.new(root: root, registry: registry)
    end
  end

  it "app/services rootへ追加された未登録fileを検知する" do
    with_scanner(
      files: {
        "app/services/analysis.rb" => "module Analysis; end\n",
        "app/services/unregistered.rb" => "module Unregistered; end\n"
      }
    ) do |scanner|
      expect(scanner.registry_issues).to include("unregistered root service: unregistered.rb")
    end
  end

  it "app/config/libから増えたroot public API利用を検知する" do
    with_scanner(
      registry: { "analysis.rb" => registry_entry(external_methods: [ :call ]) },
      files: {
        "app/services/analysis.rb" => "module Analysis; end\n",
        "app/controllers/reports_controller.rb" => "Analysis.call\n",
        "config/initializers/analysis.rb" => "Analysis.configure\n",
        "lib/tasks/analysis.rake" => "Analysis.verify\n"
      }
    ) do |scanner|
      expect(scanner.external_api_issues.sole).to include(
        "expected=[:call] actual=[:call, :configure, :verify]"
      )
    end
  end

  it "commentsとstrings内のmethod名をpublic API利用として扱わない" do
    with_scanner(
      files: {
        "app/services/analysis.rb" => "module Analysis; end\n",
        "app/controllers/reports_controller.rb" => <<~RUBY
          # Analysis.private_child
          TEXT = "Analysis.hidden_api"
        RUBY
      }
    ) do |scanner|
      expect(scanner.external_methods_for("analysis.rb", "Analysis")).to be_empty
    end
  end

  it "ReceiptとReceiptAnalysisRunへの直接status writerをreceiver付きで検知する" do
    with_scanner(
      files: {
        "app/services/analysis.rb" => "module Analysis; end\n",
        "app/controllers/receipts_controller.rb" => "@receipt.status = 'processing'\n",
        "app/services/processing.rb" => <<~RUBY
          receipt.update!(status: "completed")
          locked_run.update!(stage: "finalize", status: "running")
        RUBY
      }
    ) do |scanner|
      fingerprints = scanner.status_writes.map do |write|
        [ write.source_path, write.record_type, write.receiver_source, write.method_name, write.attributes ]
      end

      expect(fingerprints).to contain_exactly(
        [ "app/controllers/receipts_controller.rb", :receipt, "@receipt", :status=, [ :status ] ],
        [ "app/services/processing.rb", :receipt, "receipt", :update!, [ :status ] ],
        [ "app/services/processing.rb", :analysis_run, "locked_run", :update!, %i[status stage] ]
      )
    end
  end
end
