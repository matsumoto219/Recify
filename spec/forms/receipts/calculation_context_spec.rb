require "rails_helper"

RSpec.describe Receipts::CalculationContext do
  let(:user) do
    double(
      "User",
      id: 12,
      tax_rounding_mode: "floor",
      discount_rounding_mode: "round",
      default_item_tax_inclusion: "net"
    )
  end
  let(:receipt) { double("Receipt", id: 34, user_id: 12, lock_version: 2, persisted?: true) }
  let(:verifier) { Rails.application.message_verifier("receipt_calculation_context") }
  let(:purpose) { "receipt_calculation_context_v1" }

  def build_context
    described_class.build(user: user, receipt: receipt)
  end

  def verify(token, target_user: user, target_receipt: receipt)
    described_class.verify(token: token, user: target_user, receipt: target_receipt)
  end

  def signed_payload(payload)
    verifier.generate(payload, purpose: purpose)
  end

  describe ".build" do
    it "フォーム開始時の初期値と由来をimmutableなcontextへ固定する" do
      context = build_context

      aggregate_failures do
        expect(context).to be_a(Data)
        expect(context).to be_frozen
        expect(context.token).to be_frozen
        expect(context.default_for("tax_rounding_mode")).to eq("floor")
        expect(context.default_for("discount_rounding_mode")).to eq("round")
        expect(context.default_for("default_item_tax_inclusion")).to eq("net")
        expect(context.origin_for("default_item_tax_inclusion")).to eq("form_default")
        expect(context.default_for("total_amount")).to be_nil
        expect(context.default_for(:tax_rounding_mode)).to be_nil
      end
    end

    it "有効でないUser値だけをアプリ既定値へ解決する" do
      allow(user).to receive_messages(
        tax_rounding_mode: nil,
        discount_rounding_mode: "invalid",
        default_item_tax_inclusion: false
      )
      context = build_context

      aggregate_failures do
        expect(context.default_for("tax_rounding_mode")).to eq("floor")
        expect(context.default_for("discount_rounding_mode")).to eq("round")
        expect(context.default_for("default_item_tax_inclusion")).to eq("gross")
        %w[tax_rounding_mode discount_rounding_mode default_item_tax_inclusion].each do |key|
          expect(context.origin_for(key)).to eq("application_default")
        end
      end
    end

    it "Userの元Stringを変更せず、変更後も既存contextに影響させない" do
      original = +"net"
      allow(user).to receive(:default_item_tax_inclusion).and_return(original)
      context = build_context
      original.replace("gross")

      expect(context.default_for("default_item_tax_inclusion")).to eq("net")
      expect(context.default_for("default_item_tax_inclusion")).to be_frozen
    end

    it "新規フォームごとに金額を含まない別identityを発行する" do
      allow(receipt).to receive_messages(id: nil, lock_version: 0, persisted?: false)
      first = verifier.verified(build_context.token, purpose: purpose)
      second = verifier.verified(build_context.token, purpose: purpose)

      aggregate_failures do
        expect(first.keys).to match_array(%w[schema_version user_id target defaults])
        expect(first.fetch("defaults").keys).to match_array(
          %w[tax_rounding_mode discount_rounding_mode default_item_tax_inclusion]
        )
        expect(first.fetch("target").keys).to eq([ "new_form_nonce" ])
        expect(first.dig("target", "new_form_nonce")).to match(/\A[0-9a-f]{32}\z/)
        expect(first.fetch("target")).not_to eq(second.fetch("target"))
        expect(verify(signed_payload(first))).not_to be_nil
      end
    end

    it "未保存Userや別所有者のReceiptでは発行しない" do
      allow(user).to receive(:id).and_return(nil)
      expect(build_context).to be_nil
      allow(user).to receive(:id).and_return(12)
      allow(receipt).to receive(:user_id).and_return(99)
      expect(build_context).to be_nil
    end
  end

  describe ".verify" do
    it "Userの現在設定を読み直さず開始時の値を復元する" do
      token = build_context.token
      %i[tax_rounding_mode discount_rounding_mode default_item_tax_inclusion].each do |attribute|
        expect(user).not_to receive(attribute)
      end

      context = verify(token)
      expect(context.default_for("default_item_tax_inclusion")).to eq("net")
      expect(context.origin_for("default_item_tax_inclusion")).to eq("form_default")
    end

    it "別User・Receipt・lock_versionで再利用しない" do
      token = build_context.token

      aggregate_failures do
        expect(verify(token, target_user: double(id: 99))).to be_nil
        expect(verify(token, target_receipt: double(id: 35, user_id: 12, lock_version: 2, persisted?: true))).to be_nil
        expect(verify(token, target_receipt: double(id: 34, user_id: 12, lock_version: 3, persisted?: true))).to be_nil
        expect(verify(token, target_receipt: double(id: nil, user_id: 12, lock_version: 0, persisted?: false))).to be_nil
      end
    end

    it "purpose違いと署名改変を拒否する" do
      token = build_context.token
      payload = verifier.verified(token, purpose: purpose)

      aggregate_failures do
        expect(verify(verifier.generate(payload, purpose: "another_form"))).to be_nil
        expect(verify(token.reverse)).to be_nil
        expect(verify(token.sub(/.$/, token.end_with?("a") ? "b" : "a"))).to be_nil
      end
    end

    it "欠損・型違い・過長tokenはdecode前に拒否する" do
      expect(verifier).not_to receive(:verified)

      aggregate_failures do
        [ nil, false, {}, [], "", "a" * 4_097, "invalid\0token", "\xFF".b ].each do |token|
          expect(verify(token)).to be_nil
        end
      end
    end

    it "既知versionと閉じたkey・型だけを受け入れる" do
      payload = verifier.verified(build_context.token, purpose: purpose)
      malformed = [
        nil,
        [],
        {},
        payload.merge("schema_version" => 2),
        payload.merge("schema_version" => "1"),
        payload.merge("user_id" => "12"),
        payload.merge("user_id" => 12.0),
        payload.merge("price" => "100"),
        payload.merge("target" => { "id" => 34, "lock_version" => -1 }),
        payload.merge("target" => { "id" => 34, "lock_version" => 2, "name" => "untrusted" }),
        payload.merge("defaults" => payload.fetch("defaults").except("tax_rounding_mode")),
        payload.merge("defaults" => { "tax_rounding_mode" => "floor" }),
        payload.deep_merge("defaults" => { "tax_rounding_mode" => { "value" => "invalid" } }),
        payload.deep_merge("defaults" => { "tax_rounding_mode" => { "origin" => "manual" } }),
        payload.deep_merge("defaults" => { "tax_rounding_mode" => { "amount" => 100 } })
      ]

      aggregate_failures do
        malformed.each { |value| expect(verify(signed_payload(value))).to be_nil }
      end
    end

    it "新規フォームのnonce欠損・過長・形式違いを拒否する" do
      allow(receipt).to receive_messages(id: nil, lock_version: 0, persisted?: false)
      payload = verifier.verified(build_context.token, purpose: purpose)

      aggregate_failures do
        [ nil, "", "a" * 31, "a" * 33, "A" * 32, 123 ].each do |nonce|
          expect(verify(signed_payload(payload.merge("target" => { "new_form_nonce" => nonce })))).to be_nil
        end
      end
    end

    it "アプリ既定値と偽った別値は受け入れない" do
      payload = verifier.verified(build_context.token, purpose: purpose)
      payload["defaults"]["default_item_tax_inclusion"]["origin"] = "application_default"

      expect(verify(signed_payload(payload))).to be_nil
    end

    it "読み戻したcontextはdeepにimmutableで、取得した値から改変できない" do
      context = verify(build_context.token)

      aggregate_failures do
        expect(context).to be_frozen
        expect(context.defaults).to be_frozen
        expect(context.defaults.fetch("tax_rounding_mode")).to be_frozen
        expect { context.default_for("tax_rounding_mode").replace("ceil") }.to raise_error(FrozenError)
        expect { context.origin_for("tax_rounding_mode").replace("manual") }.to raise_error(FrozenError)
      end
    end

    it "フォームを保存・計算せずに検証する" do
      token = build_context.token
      expect(user).not_to receive(:save)
      expect(receipt).not_to receive(:save)
      expect(ReceiptAmountService).not_to receive(:call)
      expect(ActiveRecord::Base).not_to receive(:connection)

      expect(verify(token)).not_to be_nil
    end
  end
end
