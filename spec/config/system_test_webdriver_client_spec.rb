# frozen_string_literal: true

require "spec_helper"
require_relative "../support/system_test_webdriver_client"

RSpec.describe SystemTestWebDriverClient do
  let(:client) { described_class.new }

  before do
    client.server_url = URI("http://localhost")
  end

  [
    [ :post, "session", "new_session" ],
    [ :get, "session/private-id/window", "get_window_handle" ],
    [ :post, "session/private-id/window/rect", "set_window_rect" ],
    [ :get, "session/private-id/window/rect", "get_window_rect" ],
    [ :get, "session/private-id/private-path", "unknown" ]
  ].each do |verb, path, command|
    it "reports #{command} on a read timeout without exposing the request" do
      timeout = Net::ReadTimeout.new("private detail")
      allow(client).to receive(:request).and_raise(timeout)

      expect do
        client.call(verb, path, { value: "private payload" })
      end.to output(
        /\AWebDriver read timeout: command=#{command} request=1 elapsed_ms=\d+ selenium=#{Regexp.escape(Selenium::WebDriver::VERSION)}\n\z/
      ).to_stderr.and raise_error(Net::ReadTimeout) { |error| expect(error).to equal(timeout) }
      expect(client).to have_received(:request).once
    end
  end

  it "preserves successful responses and identifies a later timeout" do
    response = { "value" => nil }
    allow(client).to receive(:request).and_return(response)

    expect do
      expect(client.call(:post, "session/private-id/window/rect", {})).to equal(response)
    end.not_to output.to_stderr

    allow(client).to receive(:request).and_raise(Net::ReadTimeout)
    expect do
      client.call(:post, "session/private-id/window/rect", {})
    end.to output(/command=set_window_rect request=2 /).to_stderr.and raise_error(Net::ReadTimeout)
  end
end
