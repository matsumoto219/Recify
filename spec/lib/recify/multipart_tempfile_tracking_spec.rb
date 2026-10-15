require 'rails_helper'

RSpec.describe Recify::MultipartTempfileTracking do
  let(:files) { [] }
  let(:boundary) { 'synthetic-upload-boundary' }
  let(:part) do
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"synthetic.png\"\r\n" \
      "Content-Type: image/png\r\n\r\nsynthetic image bytes\r\n"
  end
  let(:factory) do
    lambda do |*|
      Tempfile.new('recify-multipart-spec').tap { |file| files << [ file, file.path ] }
    end
  end

  after do
    files.each { |file, _path| file.close! }
  end

  def environment(body)
    Rack::MockRequest.env_for(
      '/receipts/upload',
      method: 'POST',
      input: body,
      'CONTENT_TYPE' => "multipart/form-data; boundary=#{boundary}",
      'rack.multipart.tempfile_factory' => factory
    )
  end

  def application(&block)
    Rack::TempfileReaper.new(described_class.new(block))
  end

  it '不正multipartでparserが例外を返しても作成済みの一時ファイルを回収する' do
    app = application { |env| Rack::Request.new(env).POST }

    expect { app.call(environment(part)) }.to raise_error(Rack::Multipart::EmptyContentError)

    expect(files.size).to eq(1)
    expect(files).to all(satisfy { |file, path| file.closed? && !File.exist?(path) })
  end

  it '不正multipartを400応答へ変換した場合はresponse close時に回収する' do
    app = application do |env|
      Rack::Request.new(env).POST
    rescue Rack::Multipart::EmptyContentError
      [ 400, {}, [ 'invalid upload' ] ]
    end

    status, _, body = app.call(environment(part))

    expect(status).to eq(400)
    expect(File.exist?(files.sole.last)).to be(true)
    body.close

    expect(File.exist?(files.sole.last)).to be(false)
  end

  it '正常な画像本文はresponse完了まで読み取れ既存factoryをそのまま使う' do
    app = application do |env|
      upload = Rack::Request.new(env).POST.fetch('image')
      expect(upload.fetch(:tempfile).read).to eq('synthetic image bytes')
      [ 200, {}, [ 'accepted' ] ]
    end

    status, _, body = app.call(environment(part + "--#{boundary}--\r\n"))

    expect(status).to eq(200)
    expect(File.exist?(files.sole.last)).to be(true)
    body.close

    expect(File.exist?(files.sole.last)).to be(false)
  end

  it '次の一時ファイル作成が失敗した場合も先行分を回収し元の例外を維持する' do
    calls = 0
    env = environment(part + part + "--#{boundary}--\r\n")
    env['rack.multipart.tempfile_factory'] = lambda do |*arguments|
      calls += 1
      raise Errno::ENOSPC if calls == 2

      factory.call(*arguments)
    end
    app = application { |request| Rack::Request.new(request).POST }

    expect { app.call(env) }.to raise_error(Errno::ENOSPC)

    expect(files.size).to eq(1)
    expect(File.exist?(files.sole.last)).to be(false)
  end

  it 'JSON等の非multipartではfactoryや本文を変更しない' do
    env = Rack::MockRequest.env_for('/receipts', method: 'POST', input: '{}', 'CONTENT_TYPE' => 'application/json')
    app = application do |request|
      expect(request['rack.multipart.tempfile_factory']).to be_nil
      expect(request['rack.input'].read).to eq('{}')
      [ 200, {}, [] ]
    end

    app.call(env).last.close

    expect(files).to be_empty
  end

  it '本文を最初に読むMethodOverrideより前に既存Reaperと追跡を配置する' do
    middleware = Rails.application.middleware.map(&:klass)

    expect(middleware.index(Rack::TempfileReaper)).to be < middleware.index(described_class)
    expect(middleware.index(described_class)).to be < middleware.index(Rack::MethodOverride)
    expect(middleware.count(Rack::TempfileReaper)).to eq(1)
  end
end
