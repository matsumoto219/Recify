require "rails_helper"
require "fileutils"
require "tmpdir"
require_relative "../support/layer_effect_boundary_scanner"

RSpec.describe LayerEffectBoundary::Scanner do
  def with_scanner(files)
    Dir.mktmpdir("layer-effect-boundary-", Rails.root.join("tmp").to_s) do |directory|
      root = Pathname(directory)
      files.each do |relative_path, source|
        path = root.join(relative_path)
        FileUtils.mkdir_p(path.dirname)
        path.write(source)
      end

      yield described_class.new(root: root)
    end
  end

  it "QueryのDB writeを検知する" do
    with_scanner("app/queries/admin/users_query.rb" => "User.update_all(admin: true)\n") do |scanner|
      effect = scanner.layer_effects.sole
      expect(effect.to_h).to include(layer: :query, effect: :db_write, method_name: :update_all)
    end
  end

  it "Formのenqueueを検知する" do
    with_scanner("app/forms/receipts/edit_form.rb" => "ReceiptFinalizeJob.perform_later(run_id: 1)\n") do |scanner|
      effect = scanner.layer_effects.sole
      expect(effect.to_h).to include(layer: :form, effect: :async, method_name: :perform_later)
    end
  end

  it "Query/Formのproviderとaudit mutationを検知する" do
    with_scanner(
      "app/queries/receipts/unsafe_query.rb" => "ReceiptOcrService.call(receipt)\n",
      "app/forms/receipts/unsafe_form.rb" => "AuditLogs.record_admin_action!(action: 'unsafe')\n"
    ) do |scanner|
      expect(scanner.layer_effects.map(&:effect)).to contain_exactly(:provider, :audit)
    end
  end

  it "workflow facade経由のmutationも検知する" do
    with_scanner(
      "app/queries/admin/cleanup_query.rb" => "Receipts::Processing.cleanup_stale(dry_run: true)\n"
    ) do |scanner|
      effect = scanner.layer_effects.sole
      expect(effect.to_h).to include(effect: :workflow_mutation, method_name: :cleanup_stale)
    end
  end

  it "commentsとstringsをeffect callとして扱わずin-memory deleteを許可する" do
    with_scanner(
      "app/forms/receipts/edit_form.rb" => <<~RUBY
        # Receipt.create!
        TEXT = "ReceiptFinalizeJob.perform_later"
        values.delete(:blank)
      RUBY
    ) do |scanner|
      expect(scanner.layer_effects).to be_empty
    end
  end

  it "Admin controllerの直接mutationとservice renderingを検知する" do
    with_scanner(
      "app/controllers/admin/users_controller.rb" => "@user.update!(admin: true)\n",
      "app/services/status_snapshot.rb" => "renderer.render_to_string(partial: 'status')\n"
    ) do |scanner|
      expect(scanner.admin_controller_mutations.map(&:method_name)).to eq([ :update! ])
      expect(scanner.service_render_calls.map(&:method_name)).to eq([ :render_to_string ])
    end
  end

  it "将来追加されるapp/queriesとapp/formsをfilesystemから自動走査する" do
    with_scanner(
      "app/queries/new_area/report.rb" => "Report.create!\n",
      "app/forms/new_area/form.rb" => "ReportJob.perform_later\n"
    ) do |scanner|
      paths = scanner.layer_effects.map(&:source_path)
      expect(paths).to contain_exactly(
        "app/queries/new_area/report.rb",
        "app/forms/new_area/form.rb"
      )
    end
  end
end
