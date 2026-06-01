require 'rails_helper'

RSpec.describe Admin::TableHelper, type: :helper do
  describe '#admin_table_classes' do
    it 'base class and size classを返す' do
      expect(helper.admin_table_classes(size: :lg)).to eq('min-w-full text-left text-sm min-w-[72rem]')
    end

    it '追加classを末尾に付ける' do
      expect(helper.admin_table_classes(size: :sm, extra_class: 'divide-y token-border-soft')).to eq(
        'min-w-full text-left text-sm min-w-[40rem] divide-y token-border-soft'
      )
    end
  end

  describe '#admin_table_cell_classes' do
    it '列種別classを返す' do
      expect(helper.admin_table_cell_classes(type: :long_id)).to eq('font-mono text-xs whitespace-nowrap min-w-[18rem]')
      expect(helper.admin_table_cell_classes(type: :subject)).to eq('min-w-[16rem] max-w-xs truncate')
    end

    it '追加classを末尾に付ける' do
      expect(helper.admin_table_cell_classes(type: :datetime, extra_class: 'px-3 py-3')).to eq(
        'whitespace-nowrap min-w-[8rem] px-3 py-3'
      )
    end
  end
end
