# frozen_string_literal: true

require "rails_helper"

RSpec.describe Middleware::SuppressStrictTransportSecurityHeader do
  it "Strict-Transport-Securityヘッダーだけを削除する" do
    app = lambda do |_env|
      [
        200,
        {
          "Strict-Transport-Security" => "max-age=63072000; includeSubDomains",
          "Content-Type" => "text/plain"
        },
        [ "ok" ]
      ]
    end

    _status, headers, _response = described_class.new(app).call({})

    aggregate_failures do
      expect(headers).not_to include("Strict-Transport-Security")
      expect(headers).to include("Content-Type" => "text/plain")
    end
  end
end
