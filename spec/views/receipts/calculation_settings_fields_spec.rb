require "rails_helper"

RSpec.describe "receipts/_calculation_settings_fields", type: :view do
  it "丸め方2件だけを編集可能にし、丸め単位は説明付きの表示にする" do
    receipt = build(:receipt)
    presenter = ReceiptFormPresenter.new(receipt: receipt)

    render partial: "receipts/calculation_settings_fields", locals: { form_presenter: presenter, receipt: receipt }
    document = Nokogiri::HTML.fragment(rendered)

    aggregate_failures do
      expect(document.text).to include("レシート計算方式", "税率ごと")
      expect(document.css('input[type="radio"][checked]').map { |input| input["value"] }).to eq(%w[floor round])
      expect(document.css('[name="receipt_calculation_settings[tax_rounding_scope]"]')).to be_empty
      expect(document.css('input[type="radio"]').map { |input| input["name"] }.uniq).to eq(
        [ "receipt_calculation_settings[tax_rounding_mode]", "receipt_calculation_settings[discount_rounding_mode]" ]
      )
      expect(document.css('[data-controller~="segmented-control"]')).to all(
        satisfy { |control| (control["class"].split & %w[w-full md:w-auto]).size == 2 }
      )
      expect(rendered).not_to include("translation missing")
    end
  end

  [ { "schema_version" => 99 }, { "schema_version" => 1, "tax_rounding_mode" => "floor" } ].each do |settings|
    it "未対応または不正な保存条件#{settings.inspect}を丸め方の選択済み表示にしない" do
      receipt = build(:receipt, calculation_settings: settings)
      presenter = ReceiptFormPresenter.new(receipt: receipt)

      render partial: "receipts/calculation_settings_fields", locals: { form_presenter: presenter, receipt: receipt }
      document = Nokogiri::HTML.fragment(rendered)

      aggregate_failures do
        expect(document.text).to include(I18n.t("receipts.form.calculation_settings.unavailable"))
        expect(document.text).to include("税額の丸め方", "割引額の丸め方", "税額を丸める単位")
        expect(document.css('input[type="radio"]')).to be_empty
        expect(document.css('[data-controller~="segmented-control"]')).to be_empty
        expect(document.text).not_to include(I18n.t("settings.index.calculation.rounding_options.floor"))
        expect(document.text.scan(I18n.t("receipts.common.not_available")).size).to eq(3)
        expect(document.text).not_to include("per_tax_rate_group", "per_item", "per_receipt")
        expect(rendered).not_to include("translation missing")
      end
    end
  end
end
