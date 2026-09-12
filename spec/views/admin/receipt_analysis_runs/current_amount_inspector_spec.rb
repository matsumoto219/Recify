require "rails_helper"
require_relative "../../../support/current_amount_inspector_helpers"

RSpec.describe "admin/receipt_analysis_runs/_current_amount_inspector", type: :view do
  include CurrentAmountInspectorHelpers

  let(:profile) { current_amount_profile }
  let(:inspector) { Admin::CurrentAmountInspectorPresenter.new(profile) }

  def render_inspector
    render partial: "admin/receipt_analysis_runs/current_amount_inspector", locals: { inspector: inspector }

    Nokogiri::HTML.fragment(rendered)
  end

  it "現在値と6セクションを示し、保存済み比較と評価内訳を表示する" do
    document = render_inspector

    aggregate_failures do
      expect(document.at_css("h2").text).to eq("現在の計算")
      expect(document.css("h3").map(&:text)).to eq([
        "概要",
        "選択された候補",
        "候補の比較",
        "不採用理由",
        "確認判定",
        "計算根拠"
      ])
      expect(document.text).to include("解析時点の履歴ではありません")
      expect(document.text).to include("相対的なペナルティ・順位付け")
      expect(document.text).to include("確率やAIの確信度ではありません")
      expect(document.css("table")).not_to be_empty
      expect(document.css("details summary")).not_to be_empty
      expect(document.css("pre, form, button, a[download]")).to be_empty
      selected_text = document.at_css("[data-amount-inspector-section='selected']").text
      expect(selected_text.index("適格性を満たさない理由")).to be < selected_text.index("score")
    end
  end

  it "保存された空の比較候補と候補記録欠損を区別する" do
    profile["amount_engine"]["candidates"] = []
    document = render_inspector

    expect(document.at_css("[data-amount-inspector-section='comparison']").text).to include("比較候補0件")
  end

  it "税率別の割当をJSON配列としてdumpせず根拠ごとに表示する" do
    profile["profile"]["item_amount_basis_assignments"] = [
      { "tax_rate" => "0.1", "basis" => "tax_included", "net_amount" => 1000, "tax_amount" => 100, "gross_amount" => 1100 }
    ]
    document = render_inspector

    aggregate_failures do
      expect(document.at_css("[data-amount-inspector-section='summary']").text).not_to include("tax_rate", "=>")
      expect(document.at_css("[data-amount-inspector-section='evidence']").text).to include("税率別の割当 1")
      expect(document.text).not_to include("=>")
    end
  end

  it "不採用の選択候補と安全な候補なしを採用済みと表示しない" do
    profile["selected_candidate_status"] = "rejected"
    profile["amount_engine"]["selected_candidate_status"] = "rejected"
    profile["amount_engine"]["no_safe_candidate"] = true
    profile["amount_engine"]["selected_candidate"]["hard_reject_reasons"] = [ "tax_detail_mismatch" ]
    document = render_inspector

    aggregate_failures do
      expect(document.at_css("[data-amount-inspector-section='selected']").text).to include("不採用")
      expect(document.text).to include("安全な候補なし")
      expect(document.text).not_to include("採用済み")
    end
  end

  it "手動・編集の候補未記録を現在の計算として表示する" do
    profile["context"] = "edit_save"
    profile["profile"] = nil
    profile.delete("amount_engine")
    document = render_inspector

    aggregate_failures do
      expect(document.text).to include("編集保存")
      expect(document.at_css("[data-amount-inspector-section='selected']").text).to include("記録なし")
      expect(document.text).not_to include("安全な候補なし")
    end
  end

  it "review-requiredと診断warningの未保存区分を再判定しない" do
    profile["warnings"] = [ "price_tax_inclusion_uncertain" ]
    profile["warning_mismatch_codes"] = [ "PRICE_TAX_INCLUSION_UNCERTAIN" ]
    document = render_inspector
    outcome = document.at_css("[data-amount-inspector-section='review']")

    aggregate_failures do
      expect(outcome.text).to include("確認必須の警告", "診断上の警告")
      expect(outcome.text).to include("個別の区分は保存されていません")
      expect(outcome.text).to include("再判定は行いません")
    end
  end

  it "profile欠損と未知versionを区別しraw dumpしない" do
    profile.clear
    document = render_inspector
    expect(document.text).to include("現在の計算記録がありません")
    expect(document.css("pre")).to be_empty
  end

  it "未知versionと機微情報を表示しない" do
    profile["schema_version"] = 999
    profile["raw_text"] = "PRIVATE_SOURCE"
    profile["token"] = "PRIVATE_TOKEN"
    document = render_inspector

    aggregate_failures do
      expect(document.text).to include("現在の計算記録を表示できません")
      expect(document.text).not_to include("PRIVATE_SOURCE", "PRIVATE_TOKEN", "999")
    end
  end

  it "表示文字列のHTML escapeを維持する" do
    allow(inspector).to receive(:rows).and_return([ [ "<script>label</script>", "<img src=x onerror=alert(1)>" ] ])
    document = render_inspector

    aggregate_failures do
      expect(document.css("script, img")).to be_empty
      expect(document.text).to include("<script>label</script>", "<img src=x onerror=alert(1)>")
    end
  end

  it "省略がある場合に通知する" do
    allow(inspector).to receive(:omitted?).and_return(true)
    document = render_inspector

    expect(document.text).to include("表示できない項目や表示上限を超えた項目を省略しています")
  end
end
