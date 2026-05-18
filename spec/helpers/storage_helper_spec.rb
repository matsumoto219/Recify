require 'rails_helper'

RSpec.describe StorageHelper, type: :helper do
  describe '#format_storage_size' do
    it '0 bytesは単位なしで表示する' do
      expect(helper.format_storage_size(0)).to eq('0')
    end

    it '10MB未満は小数1桁で表示する' do
      expect(helper.format_storage_size(6.5.megabytes)).to eq('6.5MB')
    end

    it '10MB以上は整数で表示する' do
      expect(helper.format_storage_size(850.megabytes)).to eq('850MB')
    end

    it '10GB未満は小数1桁で表示する' do
      expect(helper.format_storage_size(1.1.gigabytes)).to eq('1.1GB')
    end

    it '10GB以上は整数で表示する' do
      expect(helper.format_storage_size(10.gigabytes)).to eq('10GB')
    end
  end
end
