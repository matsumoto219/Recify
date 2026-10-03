require 'rails_helper'

RSpec.describe 'Calculation settings preferences', type: :request do
  let(:user) { create(:user) }

  before do
    LegalDocuments::Sync.call
    sign_in user
  end

  describe 'GET /settings' do
    it '既存の計算設定カードに税区分初期値を1つだけ追加する' do
      get settings_path

      document = Nokogiri::HTML(response.body)
      options = document.css('input[name="default_item_tax_inclusion"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(options.map { |input| input['value'] }).to eq(%w[gross net])
        expect(options.select { |input| input.key?('checked') }.map { |input| input['value'] }).to eq([ 'gross' ])
        expect(document.css('input[name="tax_rounding_mode"]').size).to eq(3)
        expect(document.css('input[name="discount_rounding_mode"]').size).to eq(3)
        expect(response.body).to include('明細入力の税区分')
        expect(response.body).to include('新しく入力する明細の初期値です。明細ごとに変更できます。')
        expect(response.body).to include('※ 保存済みの計算条件を優先し、記録がない場合はこちらの設定が適用されます。')
        expect(response.body).not_to match(/translation missing/i)
      end
    end
  end

  describe 'PATCH /settings' do
    it '初期値だけを更新し、保存済みレシートの金額と条件を変更しない' do
      receipt = create(:receipt, user: user, total_amount: 201)
      before_attributes = receipt.attributes

      patch settings_path, params: { user: { default_item_tax_inclusion: 'net' } }, as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include('ok' => true, 'default_item_tax_inclusion' => 'net')
        expect(user.reload.default_item_tax_inclusion).to eq('net')
        expect(receipt.reload.attributes).to eq(before_attributes)
      end
    end

    [ nil, '', 'tax_excluded', 'GROSS', false, [], { value: 'net' } ].each do |value|
      it "不正な税区分初期値 #{value.inspect} を保存しない" do
        patch settings_path, params: { user: { default_item_tax_inclusion: value } }, as: :json

        aggregate_failures do
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body).to include('ok' => false)
          expect(user.reload.default_item_tax_inclusion).to eq('gross')
        end
      end
    end

    it '未ログインでは初期値を更新しない' do
      sign_out user

      patch settings_path, params: { user: { default_item_tax_inclusion: 'net' } }

      expect(response).to redirect_to(new_user_session_path)
      expect(user.reload.default_item_tax_inclusion).to eq('gross')
    end
  end
end
