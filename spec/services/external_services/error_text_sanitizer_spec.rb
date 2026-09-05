require 'rails_helper'

RSpec.describe ExternalServices::ErrorTextSanitizer do
  describe '.call' do
    it '上限内のmessageと長い通常のprovider識別語を保持する' do
      message = 'QuotaExceededForSubscription'

      expect(described_class.call(message)).to eq(message)
      expect(described_class.call('あ' * 166)).to eq('あ' * 166)
    end

    [
      'Bearer credential-value',
      'api_key=credential-value',
      'Authorization: credential-value',
      'client_secret=credential-value',
      'set_cookie=credential-value',
      "api\0_key=credential-value",
      'Ocp-Apim-Subscription-Key: credential-value',
      'sk-secret-token-1234567890',
      '0123456789abcdef0123456789abcdef',
      'person@example.test',
      'https://example.test/private?token=credential-value',
      '/private/evidence/response.json',
      'C:\\private\\evidence\\response.json',
      'prompt=private receipt content'
    ].each do |sensitive_value|
      it 'message内の機密値を保存しない' do
        sanitized = described_class.call("Provider failed: #{sensitive_value}")

        expect(sanitized).to include('[FILTERED]')
        expect(sanitized).not_to include(sensitive_value)
      end
    end
  end
end
