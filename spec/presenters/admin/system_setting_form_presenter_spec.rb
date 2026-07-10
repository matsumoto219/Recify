require 'rails_helper'

RSpec.describe Admin::SystemSettingFormPresenter do
  let(:form) { double('form') }

  def record(value_type:, current_value:, editable: true, **attributes)
    {
      key: 'feature.example',
      value_type: value_type,
      current_value: current_value,
      editable: editable,
      min: nil,
      max: nil,
      allowed_values: nil,
      requires_confirmation: false,
      source: 'default'
    }.merge(attributes)
  end

  describe 'update state' do
    it 'marks non editable records as readonly' do
      presenter = described_class.new(record: record(value_type: 'boolean', current_value: true, editable: false), reauthenticated: true)

      aggregate_failures do
        expect(presenter).to be_readonly
        expect(presenter).not_to be_editable
        expect(presenter).not_to be_reauthentication_required
      end
    end

    it 'requires reauthentication for editable records before reauth' do
      presenter = described_class.new(record: record(value_type: 'boolean', current_value: true), reauthenticated: false)

      expect(presenter).to be_reauthentication_required
    end
  end

  describe '#value_field_render' do
    it 'validation失敗時のvalueを現在値より優先する' do
      field = described_class.new(
        record: record(value_type: 'integer', current_value: 120),
        reauthenticated: true,
        form_values: { value: '1e2', reason: '入力を確認', confirm: '1' }
      ).value_field_render(form: form)

      aggregate_failures do
        expect(field.locals[:value]).to eq('1e2')
        expect(described_class.new(
          record: record(value_type: 'integer', current_value: 120),
          reauthenticated: true,
          form_values: { reason: '入力を確認', confirm: '1' }
        ).reason_value).to eq('入力を確認')
      end
    end
    it 'builds boolean select field config' do
      field = described_class.new(
        record: record(value_type: 'boolean', current_value: true),
        reauthenticated: true
      ).value_field_render(form: form)

      aggregate_failures do
        expect(field.partial).to eq('shared/ui/form/select_field')
        expect(field.locals[:selected]).to eq('true')
        expect(field.locals[:options]).to include([ '有効', 'true' ], [ '無効', 'false' ])
      end
    end

    it 'builds feature flag textarea with pretty JSON' do
      field = described_class.new(
        record: record(value_type: 'feature_flag', current_value: { 'enabled' => true }),
        reauthenticated: true
      ).value_field_render(form: form)

      aggregate_failures do
        expect(field.partial).to eq('shared/ui/form/textarea_field')
        expect(field.locals[:value]).to eq(JSON.pretty_generate({ 'enabled' => true }))
        expect(field.locals[:textarea_class]).to include('font-mono')
      end
    end

    it 'builds text field for regular string settings' do
      field = described_class.new(
        record: record(value_type: 'string', current_value: 'お知らせ', key: 'ui.maintenance_notice_title', max: 80),
        reauthenticated: true
      ).value_field_render(form: form)

      aggregate_failures do
        expect(field.partial).to eq('shared/ui/form/text_field')
        expect(field.locals[:value]).to eq('お知らせ')
        expect(field.locals[:html_options]).to eq(maxlength: 80)
      end
    end

    it 'integerとdurationへ整数用inputmodeを設定する' do
      %w[integer duration].each do |value_type|
        field = described_class.new(
          record: record(value_type: value_type, current_value: 120),
          reauthenticated: true
        ).value_field_render(form: form)

        expect(field.locals[:inputmode]).to eq(:numeric)
      end
    end

    it 'decimalとpercentageへ小数用inputmodeを設定する' do
      %w[decimal percentage].each do |value_type|
        field = described_class.new(
          record: record(value_type: value_type, current_value: 1.5),
          reauthenticated: true
        ).value_field_render(form: form)

        expect(field.locals[:inputmode]).to eq(:decimal)
      end
    end

    it 'builds textarea for maintenance message bodies' do
      %w[ui.maintenance_notice_body maintenance.body].each do |key|
        field = described_class.new(
          record: record(value_type: 'string', current_value: "本文1\n本文2", key: key, max: 1000),
          reauthenticated: true
        ).value_field_render(form: form)

        aggregate_failures(key) do
          expect(field.partial).to eq('shared/ui/form/textarea_field')
          expect(field.locals[:value]).to eq("本文1\n本文2")
          expect(field.locals[:rows]).to eq(5)
          expect(field.locals[:html_options]).to eq(maxlength: 1000)
        end
      end
    end
  end

  describe '#source_label' do
    it '内部sourceを管理画面向け文言へ変換する' do
      default_presenter = described_class.new(
        record: record(value_type: 'integer', current_value: 120, source: 'default'),
        reauthenticated: true
      )
      db_presenter = described_class.new(
        record: record(value_type: 'integer', current_value: 120, source: 'db'),
        reauthenticated: true
      )

      aggregate_failures do
        expect(default_presenter.source_label).to eq('アプリ既定値')
        expect(db_presenter.source_label).to eq('管理者設定')
      end
    end
  end
end
