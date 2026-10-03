require "rails_helper"

RSpec.describe Receipts::CalculationSettingsForm do
  let(:user) do
    double(
      "User",
      id: 12,
      tax_rounding_mode: "ceil",
      discount_rounding_mode: "floor",
      default_item_tax_inclusion: "net"
    )
  end
  let(:receipt) do
    double(
      "Receipt",
      id: 34,
      user_id: 12,
      lock_version: 0,
      persisted?: true,
      calculation_settings: nil,
      amount_calculation_profile: {}
    )
  end
  let(:context) { Receipts::CalculationContext.build(user: user, receipt: receipt) }
  let(:existing_purchase_adjustments) { false }
  let(:form) do
    described_class.new(
      receipt: receipt,
      context: context,
      existing_purchase_adjustments: existing_purchase_adjustments
    )
  end
  let(:saved_settings) do
    {
      "schema_version" => 1,
      "tax_rounding_mode" => { "value" => "floor", "origin" => "analysis" },
      "discount_rounding_mode" => { "value" => "round", "origin" => "manual" },
      "tax_rounding_scope" => { "value" => "per_item", "origin" => "analysis" }
    }
  end
  let(:accepted_profile) do
    {
      "schema_version" => 1,
      "context" => "edit_save",
      "selected_candidate_status" => "accepted",
      "profile" => {
        "tax_rounding_mode" => "floor",
        "discount_rounding_mode" => "round",
        "receipt_tax_basis" => "tax_added_to_subtotal",
        "item_amount_basis" => "line_total_as_net"
      },
      "amount_engine" => {
        "schema_version" => 1,
        "selected_candidate_id" => "items_net_floor",
        "no_safe_candidate" => false,
        "selected_candidate" => {
          "candidate_id" => "items_net_floor",
          "rounding_scope" => "per_item",
          "hard_reject_reasons" => []
        }
      }
    }
  end

  def item(**attributes)
    double(
      "ReceiptItem",
      **{
        persisted?: true,
        pricing_source_kind: "count_unit_price",
        input_tax_inclusion: nil,
        reference_price_tax_inclusion: nil,
        tax_inclusion_origin: nil
      }.merge(attributes)
    )
  end

  def resolve(submitted = {}, monetary_change: true, purchase_adjustments_present: false)
    form.resolve(
      submitted: submitted,
      monetary_change: monetary_change,
      purchase_adjustments_present: purchase_adjustments_present
    )
  end

  describe "display values" do
    it "有効な保存条件をUser初期値より優先する" do
      allow(receipt).to receive(:calculation_settings).and_return(saved_settings)

      aggregate_failures do
        expect(form.value_for("tax_rounding_mode")).to eq("floor")
        expect(form.origin_for("tax_rounding_mode")).to eq("analysis")
        expect(form.fallback?("tax_rounding_mode")).to be(false)
        expect(form.value_for("tax_rounding_scope")).to eq("per_item")
        expect(form.value_for("untrusted")).to be_nil
      end
    end

    it "acceptedな既存profileの厳密な値を互換読取りする" do
      allow(receipt).to receive(:amount_calculation_profile).and_return(accepted_profile)

      aggregate_failures do
        expect(form.value_for("tax_rounding_mode")).to eq("floor")
        expect(form.origin_for("tax_rounding_mode")).to eq("legacy_record")
        expect(form.value_for("tax_rounding_scope")).to eq("per_item")
        expect(form.fallback?("tax_rounding_scope")).to be(false)
        expect(form.item_value_for(item)).to eq("net")
        expect(form.item_origin_for(item)).to eq("legacy_record")
      end
    end

    it "欠損条件だけフォーム開始値とscopeのアプリ初期値で表示する" do
      aggregate_failures do
        expect(form.value_for("tax_rounding_mode")).to eq("ceil")
        expect(form.origin_for("tax_rounding_mode")).to eq("form_default")
        expect(form.value_for("discount_rounding_mode")).to eq("floor")
        expect(form.value_for("tax_rounding_scope")).to eq("per_tax_rate_group")
        expect(form.origin_for("tax_rounding_scope")).to eq("application_default")
        expect(form.fallback?("tax_rounding_scope")).to be(true)
      end
    end

    it "rejected・未知version・no-safe・型違いprofileは継承しない" do
      profiles = [
        accepted_profile.merge("selected_candidate_status" => "rejected"),
        accepted_profile.merge("schema_version" => "1"),
        accepted_profile.merge("schema_version" => 2),
        accepted_profile.deep_merge("amount_engine" => { "no_safe_candidate" => true }),
        accepted_profile.deep_merge("amount_engine" => { "no_safe_candidate" => "false" }),
        accepted_profile.merge("profile" => "untrusted")
      ]

      aggregate_failures do
        profiles.each do |profile|
          allow(receipt).to receive(:amount_calculation_profile).and_return(profile)
          current = described_class.new(receipt: receipt, context: context)
          expect(current.value_for("tax_rounding_mode")).to eq("ceil")
          expect(current.item_origin_for(item)).to eq("form_default")
        end
      end
    end

    it "選択candidateのidentity不一致ではscopeを推測しない" do
      profile = accepted_profile.deep_merge(
        "amount_engine" => { "selected_candidate_id" => "different" }
      )
      allow(receipt).to receive(:amount_calculation_profile).and_return(profile)

      expect(form.value_for("tax_rounding_scope")).to eq("per_tax_rate_group")
      expect(form.fallback?("tax_rounding_scope")).to be(true)
    end

    it "typed item自身のbasisを優先し、新規明細へ既存Receiptのbasisを引き継がない" do
      allow(receipt).to receive(:amount_calculation_profile).and_return(accepted_profile)

      aggregate_failures do
        expect(form.item_value_for(item(input_tax_inclusion: "gross", tax_inclusion_origin: "manual"))).to eq("gross")
        expect(form.item_origin_for(item(input_tax_inclusion: "gross", tax_inclusion_origin: "manual"))).to eq("manual")
        expect(form.item_value_for(item(persisted?: false))).to eq("net")
        expect(form.item_origin_for(item(persisted?: false))).to eq("form_default")
        expect(form.item_value_for(item(pricing_source_kind: "reference_quantity_price", reference_price_tax_inclusion: "gross"))).to eq("gross")
      end
    end

    it "profilelessの税抜candidate名を保存済みnet sourceと誤認しない" do
      profile = {
        "schema_version" => 1,
        "selected_candidate_status" => "accepted",
        "amount_engine" => { "selected_basis" => "items_as_tax_excluded" }
      }
      allow(receipt).to receive(:amount_calculation_profile).and_return(profile)

      expect(form.item_value_for(item)).to eq("gross")
      expect(form.item_origin_for(item)).to eq("legacy_record")
    end

    it "旧explicitのgross契約をReceiptのnet推定やreference診断で上書きしない" do
      allow(receipt).to receive(:amount_calculation_profile).and_return(accepted_profile)
      explicit = item(pricing_source_kind: "explicit_line_total", reference_price_tax_inclusion: "net")

      expect(form.item_value_for(explicit)).to eq("gross")
      expect(form.item_origin_for(explicit)).to eq("legacy_record")
    end

    it "旧analysisの未分類gross投影をnet入力と誤認せず、typed countのsourceは区別する" do
      stored = Receipt.new(
        amount_calculation_profile: {
          schema_version: 1,
          context: "analysis",
          selected_candidate_status: "accepted",
          profile: {
            receipt_tax_basis: "tax_added_to_subtotal",
            item_amount_basis: "line_total_as_net"
          },
          amount_engine: {
            schema_version: 1,
            selected_candidate_status: "accepted",
            no_safe_candidate: false,
            selected_basis: "items_as_tax_excluded",
            selected_candidate_id: "items_as_tax_excluded/floor/per_item",
            selected_candidate: {
              candidate_id: "items_as_tax_excluded/floor/per_item",
              basis: "items_as_tax_excluded",
              rounding_mode: "floor",
              rounding_scope: "per_item",
              hard_reject_reasons: []
            }
          }
        }
      )
      current = described_class.new(receipt: stored, context: context)

      expect(current.item_value_for(item(pricing_source_kind: nil))).to eq("gross")
      expect(current.item_value_for(item)).to eq("net")
      stored.receipt_items.build(price: 110, quantity: 1, line_total: 110)
      expect(stored.amount_source_semantics_for_edit).to eq(
        "receipt_tax_basis" => "total_includes_tax",
        "item_amount_basis" => "line_total_as_recorded"
      )
      stored.amount_calculation_profile["context"] = "edit_save"
      current = described_class.new(receipt: stored, context: context)
      expect(current.item_value_for(item(pricing_source_kind: nil))).to eq("net")
      expect(stored.amount_source_semantics_for_edit["item_amount_basis"]).to eq("line_total_as_net")
      stored.amount_calculation_profile["context"] = "manual"
      current = described_class.new(receipt: stored, context: context)
      expect(current.item_value_for(item)).to eq("gross")
    end
  end

  describe "receipt settings resolution" do
    it "未使用の初期値を非金額保存でmaterializeしない" do
      result = resolve(
        { "tax_rounding_mode" => "ceil", "discount_rounding_mode" => "floor" },
        monetary_change: false
      )

      expect(result).to be_a(Data)
      expect(result).to be_frozen
      expect(result).to be_success
      expect(result.attributes).to eq({})
    end

    it "金額変更時に実際に使う条件だけを由来付きで返す" do
      result = resolve

      expect(result).to be_success
      expect(result.attributes.fetch("calculation_settings")).to eq(
        "schema_version" => 1,
        "tax_rounding_mode" => { "value" => "ceil", "origin" => "form_default" },
        "discount_rounding_mode" => { "value" => "floor", "origin" => "form_default" },
        "tax_rounding_scope" => { "value" => "per_tax_rate_group", "origin" => "application_default" }
      )
    end

    it "同値echoは元のoriginを保持し、変更した条件だけmanualになる" do
      allow(receipt).to receive(:calculation_settings).and_return(saved_settings)
      unchanged = resolve({ "tax_rounding_mode" => "floor" })
      changed = resolve({ "tax_rounding_mode" => "ceil" })

      aggregate_failures do
        expect(unchanged.attributes).to eq({})
        expect(changed.attributes.dig("calculation_settings", "tax_rounding_mode")).to eq(
          "value" => "ceil", "origin" => "manual"
        )
        expect(changed.attributes.dig("calculation_settings", "discount_rounding_mode")).to eq(
          saved_settings.fetch("discount_rounding_mode")
        )
        expect(saved_settings.dig("tax_rounding_mode", "value")).to eq("floor")
      end
    end

    it "contextなしでも具体的な手動入力が揃えば受け入れる" do
      current = described_class.new(receipt: receipt, context: nil)
      result = current.resolve(
        submitted: { "tax_rounding_mode" => "floor", "discount_rounding_mode" => "round" },
        monetary_change: true,
        purchase_adjustments_present: false
      )

      expect(result).to be_success
      expect(result.attributes.dig("calculation_settings", "tax_rounding_mode", "origin")).to eq("manual")
      missing = current.resolve(submitted: {}, monetary_change: true, purchase_adjustments_present: false)
      expect(missing.errors).to include("tax_rounding_mode" => :missing, "discount_rounding_mode" => :missing)
      expect(missing.attributes).to eq({})
    end

    it "明示blank・未知enum・origin注入・scope変更は非金額保存でも拒否する" do
      invalid = [
        { "tax_rounding_mode" => "" },
        { "tax_rounding_mode" => [] },
        { "discount_rounding_mode" => "ROUND" },
        { "origin" => "manual" },
        { "tax_rounding_scope" => "per_item" },
        { tax_rounding_mode: "floor" },
        "untrusted"
      ]

      aggregate_failures do
        invalid.each do |submitted|
          result = resolve(submitted, monetary_change: false)
          expect(result).not_to be_success
          expect(result.attributes).to eq({})
        end
      end
    end

    it "未知の保存JSONは表示不可、非金額保存で維持、金額変更で拒否する" do
      unknown = { "schema_version" => 2, "private" => "untrusted" }
      allow(receipt).to receive(:calculation_settings).and_return(unknown)

      aggregate_failures do
        expect(form).to be_invalid_saved_settings
        expect(form.value_for("tax_rounding_mode")).to be_nil
        expect(resolve({}, monetary_change: false)).to be_success
        expect(resolve({}, monetary_change: false).attributes).to eq({})
        expect(resolve.errors).to eq("calculation_settings" => :unavailable)
        expect(unknown).to eq("schema_version" => 2, "private" => "untrusted")
      end
    end

    it "初めての購入調整は明細初期値と独立したgrossを使う" do
      allow(receipt).to receive(:amount_calculation_profile).and_return(accepted_profile)
      result = resolve({}, purchase_adjustments_present: true)

      expect(result.attributes.dig("calculation_settings", "purchase_adjustment_tax_inclusion")).to eq(
        "value" => "gross", "origin" => "application_default"
      )
    end

    context "with existing purchase adjustments" do
      let(:existing_purchase_adjustments) { true }

      it "不明な旧調整basisは表示でも金額保存でも勝手に決めない" do
        result = resolve({}, purchase_adjustments_present: true)

        aggregate_failures do
          expect(form.value_for("purchase_adjustment_tax_inclusion")).to be_nil
          expect(result.errors).to include("purchase_adjustment_tax_inclusion" => :confirmation_required)
          expect(result.attributes).to eq({})
          expect(resolve({}, monetary_change: false, purchase_adjustments_present: true)).to be_success
        end
      end

      it "調整欄の明示選択だけで不明basisを解決する" do
        result = resolve({ "purchase_adjustment_tax_inclusion" => "net" }, purchase_adjustments_present: true)

        expect(result).to be_success
        expect(result.attributes.dig("calculation_settings", "purchase_adjustment_tax_inclusion")).to eq(
          "value" => "net", "origin" => "manual"
        )
      end

      it "厳密な旧profileがある場合はその調整basisを保持する" do
        allow(receipt).to receive(:amount_calculation_profile).and_return(accepted_profile)

        expect(form.value_for("purchase_adjustment_tax_inclusion")).to eq("net")
        expect(resolve({}, purchase_adjustments_present: true)).to be_success
      end
    end
  end

  describe "item basis resolution" do
    it "同値echoだけではbasis/originを新規保存しない" do
      result = form.resolve_item(
        item: item,
        submitted: { "input_tax_inclusion" => "net" },
        monetary_change: false
      )

      expect(result).to be_success
      expect(result.attributes).to eq({})
    end

    it "元からあるbasisとoriginを同値保存で維持する" do
      result = form.resolve_item(
        item: item(input_tax_inclusion: "gross", tax_inclusion_origin: "analysis"),
        submitted: { "input_tax_inclusion" => "gross" },
        monetary_change: true
      )

      expect(result).to be_success
      expect(result.attributes).to eq({})
    end

    it "明示変更は価格や数量を変えずbasisとmanual originだけを返す" do
      result = form.resolve_item(
        item: item(input_tax_inclusion: "gross", tax_inclusion_origin: "analysis"),
        submitted: { "input_tax_inclusion" => "net" },
        monetary_change: true
      )

      expect(result.attributes).to eq("input_tax_inclusion" => "net", "tax_inclusion_origin" => "manual")
    end

    it "referenceへのmode変更はcount用basisを消す" do
      result = form.resolve_item(
        item: item(input_tax_inclusion: "gross", tax_inclusion_origin: "manual"),
        submitted: { "pricing_source_kind" => "reference_quantity_price", "reference_price_tax_inclusion" => "net" },
        monetary_change: true
      )

      expect(result.attributes).to eq(
        "input_tax_inclusion" => nil,
        "reference_price_tax_inclusion" => "net",
        "tax_inclusion_origin" => "manual"
      )
    end

    it "referenceから離れる場合だけ旧reference basisを消す" do
      result = form.resolve_item(
        item: item(pricing_source_kind: "reference_quantity_price", reference_price_tax_inclusion: "gross"),
        submitted: { "pricing_source_kind" => "explicit_line_total", "input_tax_inclusion" => "gross" },
        monetary_change: true
      )

      expect(result.attributes).to eq(
        "reference_price_tax_inclusion" => nil,
        "input_tax_inclusion" => "gross",
        "tax_inclusion_origin" => "legacy_record"
      )
    end

    it "既存explicitのreference diagnostic basisはactive basisと混同しない" do
      current = item(
        pricing_source_kind: "explicit_line_total",
        input_tax_inclusion: "gross",
        reference_price_tax_inclusion: "net",
        tax_inclusion_origin: "manual"
      )
      result = form.resolve_item(item: current, submitted: {}, monetary_change: true)

      expect(form.item_value_for(current)).to eq("gross")
      expect(result.attributes).to eq({})
    end

    it "legacy kindなしへbasisや架空のkindを書かない" do
      current = item(pricing_source_kind: nil)
      unchanged = form.resolve_item(item: current, submitted: { "input_tax_inclusion" => "net" }, monetary_change: true)
      changed = form.resolve_item(item: current, submitted: { "input_tax_inclusion" => "gross" }, monetary_change: true)

      expect(unchanged.attributes).to eq({})
      expect(changed.errors).to eq("pricing_source_kind" => :missing)
    end

    it "非選択modeのbasis、client origin、不正値を受け入れない" do
      invalid = [
        { "input_tax_inclusion" => "" },
        { "input_tax_inclusion" => "NET" },
        { "input_tax_inclusion" => 0 },
        { "reference_price_tax_inclusion" => "gross" },
        { "tax_inclusion_origin" => "manual" },
        { "gross_line_total" => 100 },
        { "pricing_source_kind" => "unknown" },
        { "pricing_source_kind" => nil }
      ]

      aggregate_failures do
        invalid.each do |submitted|
          result = form.resolve_item(item: item, submitted: submitted, monetary_change: false)
          expect(result).not_to be_success
          expect(result.attributes).to eq({})
        end
      end
    end

    it "contextなしでbasis欠損なら初期値を歴史上の選択として保存しない" do
      current = described_class.new(receipt: receipt, context: nil)
      result = current.resolve_item(item: item, submitted: {}, monetary_change: true)

      expect(result.errors).to eq("input_tax_inclusion" => :missing)
    end
  end

  it "入力と保存値を変更せず、DB取得・保存・計算を呼ばない" do
    submitted = { "tax_rounding_mode" => "floor" }
    context
    expect(receipt).not_to receive(:receipt_items)
    expect(receipt).not_to receive(:receipt_adjustments)
    expect(receipt).not_to receive(:receipt_tax_details)
    expect(receipt).not_to receive(:save)
    expect(ReceiptAmountService).not_to receive(:call)
    result = resolve(submitted)

    expect(submitted).to eq("tax_rounding_mode" => "floor")
    expect(result.attributes).to be_frozen
    expect(result.attributes.fetch("calculation_settings")).to be_frozen
    expect(result.attributes.dig("calculation_settings", "tax_rounding_mode")).to be_frozen
    expect(result.attributes.dig("calculation_settings", "tax_rounding_mode", "value")).to be_frozen
    expect(result.errors).to be_frozen
  end
end
