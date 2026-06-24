require 'rails_helper'

RSpec.describe 'Kamal deploy config' do
  around do |example|
    original_deploy_host = ENV['KAMAL_DEPLOY_HOST']
    original_app_host = ENV['APP_HOST']

    ENV['KAMAL_DEPLOY_HOST'] = 'example-host'
    ENV['APP_HOST'] = 'example.com'

    example.run
  ensure
    ENV['KAMAL_DEPLOY_HOST'] = original_deploy_host
    ENV['APP_HOST'] = original_app_host
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
end
