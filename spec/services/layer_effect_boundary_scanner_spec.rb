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

  it "静的method名のdynamic dispatchによる副作用を検知する" do
    with_scanner(
      "app/queries/unsafe_query.rb" => <<~RUBY,
        record.public_send(:save!)
        ReceiptOcrService.send(:call, receipt)
        AuditLogs.__send__(:record_admin_action!, action: "unsafe")
        Receipts::Processing.public_send(:cleanup_stale, dry_run: true)
        Receipts::Editing.send(:create_manual, receipt: receipt)
        Receipts::Uploads.__send__(:single, user: user, image: image)
      RUBY
      "app/forms/unsafe_form.rb" => "ReceiptFinalizeJob.public_send(:perform_later, run_id: 1)\n"
    ) do |scanner|
      expect(scanner.layer_effects.map { |effect| [ effect.effect, effect.method_name ] }).to contain_exactly(
        [ :db_write, :save! ],
        [ :provider, :call ],
        [ :audit, :record_admin_action! ],
        [ :workflow_mutation, :cleanup_stale ],
        [ :workflow_mutation, :create_manual ],
        [ :workflow_mutation, :single ],
        [ :async, :perform_later ]
      )
    end
  end

  it "重要facadeのaliasをQuery/FormとAdmin controllerで検知する" do
    with_scanner(
      "app/queries/unsafe_query.rb" => "processor = Receipts::Processing\nprocessor.cleanup_stale\n",
      "app/forms/unsafe_form.rb" => "@provider = ReceiptOcrService\n",
      "app/controllers/settings_controller.rb" => <<~RUBY
        operations = SystemOperations
        operations.update_setting
        Object.const_get("SystemOperations").update_setting
      RUBY
    ) do |scanner|
      expect(scanner.layer_effects.map { |effect| [ effect.effect, effect.receiver_constant ] }).to contain_exactly(
        [ :facade_alias, "Receipts::Processing" ],
        [ :facade_alias, "ReceiptOcrService" ]
      )
      expect(scanner.high_risk_facade_aliases.map(&:receiver_constant)).to eq(
        [ "SystemOperations", "SystemOperations" ]
      )
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
