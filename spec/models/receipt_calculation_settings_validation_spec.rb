require 'rails_helper'

RSpec.describe Receipt, type: :model do
  describe 'calculation settings validation' do
    let(:settings) do
      {
        'schema_version' => 1,
        'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'manual' }
      }
    end

    it '旧記録のNULLを補完せず許可する' do
      receipt = build(:receipt, calculation_settings: nil)

      expect(receipt).to be_valid
      expect(receipt.calculation_settings).to be_nil
    end

    it '変更された有効な部分設定をそのまま許可する' do
      receipt = build(:receipt, calculation_settings: settings)

      expect(receipt).to be_valid
      expect(receipt.calculation_settings).to eq(settings)
    end

    it '変更された不正形式をgenericなエラーで拒否する' do
      invalid_values = [
        {},
        [],
        'private-calculation-payload',
        settings.merge('schema_version' => 2),
        settings.merge('private' => 'private-calculation-payload')
      ]

      invalid_values.each do |value|
        receipt = build(:receipt, calculation_settings: value)

        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:calculation_settings, :invalid)).to be(true)
        expect(receipt.errors.full_messages.join).not_to include('private-calculation-payload')
      end
    end

    it '変更されていない未知の旧JSONは非金額編集で再検証・補正しない' do
      stored = create(:receipt, :completed)
      unknown_settings = { 'schema_version' => 2, 'unsupported' => 'retained' }
      receipt = described_class.instantiate(stored.attributes.merge('calculation_settings' => unknown_settings))
      receipt.memo = '編集したメモ'

      aggregate_failures do
        expect(receipt.will_save_change_to_calculation_settings?).to be(false)
        expect(receipt).to be_valid
        expect(receipt.calculation_settings).to eq(unknown_settings)
      end
    end

    it '保存済みの設定を未知形式へ変更した場合は拒否する' do
      receipt = create(:receipt, :completed, calculation_settings: settings)
      receipt.calculation_settings = { 'schema_version' => 2, 'unsupported' => 'retained' }

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:calculation_settings, :invalid)).to be(true)
    end

    it '明示再解析によるNULLへの変更は許可する' do
      receipt = create(:receipt, :completed, calculation_settings: settings)
      receipt.calculation_settings = nil

      expect(receipt).to be_valid
      expect(receipt.calculation_settings).to be_nil
    end
  end
end
