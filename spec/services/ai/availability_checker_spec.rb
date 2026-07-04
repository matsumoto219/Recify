require 'rails_helper'

RSpec.describe Ai::AvailabilityChecker do
  let(:configured_env) do
    {
      'RECEIPT_AI_ENABLED' => 'true',
      'AI_PRIMARY_PROVIDER' => 'openai',
      'AI_FALLBACK_PROVIDER' => nil,
      'OPENAI_API_KEY' => 'test-openai-key',
      'OPENAI_AI_MODEL' => 'gpt-test'
    }
  end

  it '設定が揃っている場合は true を返し Ai::Client を呼ばない' do
    with_env(configured_env) do
      expect(Ai::Client).not_to receive(:new)

      expect(described_class.call).to eq(true)
    end
  end

  it 'operations.ai_enabled が false の場合は false を返す' do
    create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))

    with_env(configured_env) do
      expect(described_class.call).to eq(false)
    end
  end

  it 'operations.ai_enabled の取得に失敗した場合は fail-closed で false を返す' do
    allow(SystemSettings).to receive(:enabled?)
      .with('operations.ai_enabled')
      .and_raise(SystemSettings::UnknownKeyError, 'operations.ai_enabled')

    with_env(configured_env) do
      expect(described_class.call).to eq(false)
    end
  end

  it 'RECEIPT_AI_ENABLED が false の場合は false を返す' do
    with_env(configured_env.merge('RECEIPT_AI_ENABLED' => 'false')) do
      expect(described_class.call).to eq(false)
    end
  end

  it 'API key がない場合は false を返す' do
    with_env(configured_env.merge('OPENAI_API_KEY' => nil)) do
      expect(described_class.call).to eq(false)
    end
  end

  it 'model 設定がない場合は false を返す' do
    with_env(configured_env.merge('OPENAI_AI_MODEL' => nil)) do
      expect(described_class.call).to eq(false)
    end
  end

  it '未実装 primary provider の場合は false を返す' do
    with_env(configured_env.merge('AI_PRIMARY_PROVIDER' => 'gemini')) do
      expect(described_class.call).to eq(false)
    end
  end

  it '未実装 fallback provider が設定されている場合は false を返す' do
    with_env(configured_env.merge('AI_FALLBACK_PROVIDER' => 'claude')) do
      expect(described_class.call).to eq(false)
    end
  end

  it '例外時は false を返す' do
    allow(Ai::ProviderRegistry).to receive(:fetch).and_raise(StandardError, 'boom')

    with_env(configured_env) do
      expect(described_class.call).to eq(false)
    end
  end

  def with_env(overrides)
    previous_values = overrides.keys.to_h do |key|
      [ key, ENV.key?(key) ? ENV[key] : :__unset__ ]
    end

    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous_values.each do |key, value|
      if value == :__unset__
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
