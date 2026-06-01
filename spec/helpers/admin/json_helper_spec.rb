require 'rails_helper'

RSpec.describe Admin::JsonHelper, type: :helper do
  describe '#admin_pretty_json' do
    it 'returns pretty generated JSON' do
      expect(helper.admin_pretty_json({ ok: true })).to eq(JSON.pretty_generate({ ok: true }))
    end
  end
end
