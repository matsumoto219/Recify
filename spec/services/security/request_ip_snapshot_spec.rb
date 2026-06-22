# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::RequestIpSnapshot do
  IpSnapshotFakeRequest = Struct.new(:ip, :remote_ip, :headers, keyword_init: true) do
    def get_header(name)
      headers[name]
    end
  end

  def request_with(ip:, remote_ip:, headers: {})
    IpSnapshotFakeRequest.new(ip: ip, remote_ip: remote_ip, headers: headers)
  end

  it 'Cloudflare headersがありrequest.ip/remote_ipが一致すればokにする' do
    request = request_with(
      ip: '8.8.8.8',
      remote_ip: '8.8.8.8',
      headers: {
        'HTTP_CF_CONNECTING_IP' => '8.8.8.8',
        'HTTP_CF_RAY' => 'ray-id',
        'HTTP_X_FORWARDED_FOR' => '8.8.8.8, 172.70.0.1'
      }
    )

    snapshot = described_class.call(request: request)

    aggregate_failures do
      expect(snapshot[:status]).to eq('ok')
      expect(snapshot[:rack_attack_ip]).to eq('8.8.8.8')
      expect(snapshot[:rack_attack_source]).to eq('request.ip')
      expect(snapshot.dig(:cloudflare, :likely)).to be(true)
      expect(snapshot.dig(:cloudflare, :header_keys)).to include('CF-Connecting-IP', 'CF-Ray')
      expect(snapshot.dig(:forwarded, :count)).to eq(2)
    end
  end

  it 'Cloudflare headersがなければwarningにする' do
    request = request_with(ip: '127.0.0.1', remote_ip: '127.0.0.1')

    snapshot = described_class.call(request: request)

    aggregate_failures do
      expect(snapshot[:status]).to eq('warning')
      expect(snapshot.dig(:cloudflare, :likely)).to be(false)
      expect(snapshot.dig(:forwarded, :present)).to be(false)
      expect(snapshot[:checks].map { |check| check[:message_key] }).to include('admin.ip_diagnostics.checks.cloudflare_headers_missing')
    end
  end

  it 'X-Forwarded-Forが複数ある場合は分割して件数と省略数を返す' do
    request = request_with(
      ip: '8.8.8.8',
      remote_ip: '8.8.8.8',
      headers: {
        'HTTP_X_FORWARDED_FOR' => '8.8.8.8, 1.1.1.1, 9.9.9.9, 208.67.222.222, 208.67.220.220, 64.6.64.6'
      }
    )

    snapshot = described_class.call(request: request)

    aggregate_failures do
      expect(snapshot[:status]).to eq('warning')
      expect(snapshot.dig(:forwarded, :count)).to eq(6)
      expect(snapshot.dig(:forwarded, :values)).to eq(%w[8.8.8.8 1.1.1.1 9.9.9.9 208.67.222.222 208.67.220.220])
      expect(snapshot.dig(:forwarded, :omitted_count)).to eq(1)
      expect(snapshot.dig(:headers, 'X-Forwarded-For', :count)).to eq(6)
    end
  end

  it 'Cloudflare client IPとRack::Attack想定IPがずれた場合はdangerにする' do
    request = request_with(
      ip: '172.70.0.1',
      remote_ip: '172.70.0.1',
      headers: {
        'HTTP_CF_CONNECTING_IP' => '8.8.8.8',
        'HTTP_X_FORWARDED_FOR' => '8.8.8.8, 172.70.0.1'
      }
    )

    snapshot = described_class.call(request: request)

    aggregate_failures do
      expect(snapshot[:status]).to eq('danger')
      expect(snapshot[:checks].map { |check| check[:message_key] }).to include(
        'admin.ip_diagnostics.checks.rack_attack_ip_mismatch',
        'admin.ip_diagnostics.checks.remote_ip_mismatch'
      )
    end
  end

  it 'requestがnilならunknownにする' do
    snapshot = described_class.call(request: nil)

    aggregate_failures do
      expect(snapshot[:status]).to eq('unknown')
      expect(snapshot[:rack_attack_ip]).to be_nil
      expect(snapshot[:checks].map { |check| check[:message_key] }).to include('admin.ip_diagnostics.checks.no_request')
    end
  end
end
