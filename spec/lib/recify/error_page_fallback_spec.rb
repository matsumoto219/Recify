require 'rails_helper'

RSpec.describe Recify::ErrorPageFallback do
  let(:application) { double('exceptions application') }
  let(:logger) { double('logger', error: nil) }
  let(:fallback) { described_class.new(application, public_path: Rails.public_path, logger: logger) }
  let(:env) { Rack::MockRequest.env_for('/500').merge('action_dispatch.request_id' => 'request-123') }

  it 'preserves a successful dynamic error response' do
    response = [ 404, { 'content-type' => 'text/html' }, [ 'dynamic error' ] ]
    allow(application).to receive(:call).and_return(response)

    expect(fallback.call(env)).to equal(response)
  end

  it 'serves the static Recify page when the dynamic error page also fails' do
    allow(application).to receive(:call).and_raise(ActiveRecord::ConnectionNotDefined, 'private detail')

    status, headers, body = fallback.call(env)

    aggregate_failures do
      expect(status).to eq(500)
      expect(headers['content-type']).to include('text/html')
      expect(headers['cache-control']).to eq('no-store')
      expect(body.join).to include('Recify', 'Error Code: 500')
      expect(body.join).not_to include('private detail', 'ConnectionNotDefined')
      expect(logger).to have_received(:error).with('[ErrorPageFallback] status=500 request_id=request-123 exception_class=ActiveRecord::ConnectionNotDefined')
    end
  end

  it 'changes a failed 404 renderer to a static 500' do
    env['PATH_INFO'] = '/404'
    allow(application).to receive(:call).and_raise(RuntimeError)

    status, _, body = fallback.call(env)

    expect(status).to eq(500)
    expect(body.join).to include('Error Code: 500')
  end

  it 'keeps a safe JSON representation for JSON requests' do
    env['HTTP_ACCEPT'] = 'application/json'
    allow(application).to receive(:call).and_raise(RuntimeError, 'private detail')

    status, headers, body = fallback.call(env)

    expect(status).to eq(500)
    expect(headers['content-type']).to include('application/json')
    expect(JSON.parse(body.join)).to eq('status' => 500, 'error' => 'Internal Server Error')
  end

  it 'returns no body for an original HEAD request' do
    env['action_dispatch.original_request_method'] = 'HEAD'
    allow(application).to receive(:call).and_raise(RuntimeError)

    status, headers, body = fallback.call(env)

    expect(status).to eq(500)
    expect(headers['cache-control']).to eq('no-store')
    expect(body).to eq([])
  end

  it 'does not let logging failure hide the static response' do
    allow(application).to receive(:call).and_raise(RuntimeError)
    allow(logger).to receive(:error).and_raise(IOError)

    expect(fallback.call(env).last.join).to include('Recify')
  end

  it 'omits malformed request identifiers from the fallback log' do
    env['action_dispatch.request_id'] = "private@example.test\nforged log"
    allow(application).to receive(:call).and_raise(RuntimeError)

    fallback.call(env)

    expect(logger).to have_received(:error).with('[ErrorPageFallback] status=500 request_id=nil exception_class=RuntimeError')
  end

  it 'terminates safely when the static page is unavailable' do
    allow(application).to receive(:call).and_raise(RuntimeError)
    missing = described_class.new(application, public_path: Rails.root.join('tmp/missing-error-pages'), logger: logger)

    status, headers, body = missing.call(env)

    expect(status).to eq(500)
    expect(headers['cache-control']).to eq('no-store')
    expect(body.join).to eq('500 Internal Server Error')
    expect(application).to have_received(:call).once
  end
end
