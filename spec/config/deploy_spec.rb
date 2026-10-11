require 'rails_helper'

RSpec.describe 'Kamal deploy config' do
  around do |example|
    original_deploy_host = ENV['KAMAL_DEPLOY_HOST']
    original_app_host = ENV['APP_HOST']
    original_ai_model = ENV['OPENAI_AI_MODEL']

    ENV['KAMAL_DEPLOY_HOST'] = 'example-host'
    ENV['APP_HOST'] = 'example.com'

    example.run
  ensure
    ENV['KAMAL_DEPLOY_HOST'] = original_deploy_host
    ENV['APP_HOST'] = original_app_host
    ENV['OPENAI_AI_MODEL'] = original_ai_model
  end

  let(:config) do
    YAML.safe_load(
      ERB.new(Rails.root.join('config/deploy.yml').read).result,
      aliases: true
    )
  end

  it 'disables Thruster request logs so raw query tokens are not emitted before Rails filtering' do
    expect(config.dig('env', 'clear', 'THRUSTER_LOG_REQUESTS')).to eq('false')
  end

  [ nil, '', '   ' ].each do |model|
    it "does not require a model secret for #{model.inspect}" do
      ENV['OPENAI_AI_MODEL'] = model

      expect(config.dig('env', 'secret')).not_to include('OPENAI_AI_MODEL')
      expect(config.dig('env', 'secret')).to include('OPENAI_API_KEY')
    end
  end

  it 'preserves an explicit model override in container configuration' do
    ENV['OPENAI_AI_MODEL'] = 'custom-model'

    expect(config.dig('env', 'secret')).to include('OPENAI_AI_MODEL')
  end
end
