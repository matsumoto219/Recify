require 'rails_helper'

RSpec.describe Admin::JsonHelper, type: :helper do
  describe '#admin_json_container_classes' do
    it 'returns classes that keep JSON blocks inside their parent width' do
      expect(helper.admin_json_container_classes).to eq('min-w-0 max-w-full')
    end

    it 'appends extra classes' do
      expect(helper.admin_json_container_classes(extra_class: 'mt-3')).to eq('min-w-0 max-w-full mt-3')
    end
  end

  describe '#admin_json_pre_classes' do
    it 'returns horizontal scroll classes for compact JSON blocks' do
      expect(helper.admin_json_pre_classes).to include('max-w-full')
      expect(helper.admin_json_pre_classes).to include('whitespace-pre')
      expect(helper.admin_json_pre_classes).to include('overflow-x-auto')
    end

    it 'returns bounded scroll classes for detailed JSON blocks' do
      classes = helper.admin_json_pre_classes(details: true)

      expect(classes).to include('max-w-full')
      expect(classes).to include('whitespace-pre')
      expect(classes).to include('max-h-[32rem] overflow-auto')
    end
  end

  describe '#admin_pretty_json' do
    it 'returns pretty generated JSON' do
      expect(helper.admin_pretty_json({ ok: true })).to eq(JSON.pretty_generate({ ok: true }))
    end
  end
end
