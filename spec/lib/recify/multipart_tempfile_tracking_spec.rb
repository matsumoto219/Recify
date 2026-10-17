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

  context '既定の一時ファイルを使う場合' do
    let(:factory) { nil }
    let(:anonymous_files) { [] }

    before do
      allow(Tempfile).to receive(:create).and_wrap_original do |original, *arguments, **options|
        original.call(*arguments, **options).tap { |file| anonymous_files << file }
      end
    end

    after do
      anonymous_files.each(&:close)
    end

    it '名前を残さず本文を読み取れRailsの画像代入で開き直しても内容を維持する' do
      binary = "synthetic \x00\xFF\x80\r\nimage bytes".b
      app = application do |env|
        upload = ActionDispatch::Http::UploadedFile.new(Rack::Request.new(env).POST.fetch('image'))
        expect(upload.tempfile.stat.nlink).to eq(0)
        expect(upload.original_filename).to eq('synthetic.png')
        expect(upload.content_type).to eq('image/png')

        io = upload.open
        expect(io).to be_a(File)
        expect(io.binmode?).to be(true)
        expect(io.read).to eq(binary)
        expect(upload.open).to equal(io)
        buffer = String.new
        expect(upload.read(9, buffer)).to equal(buffer)
        expect(buffer).to eq('synthetic')

        blob = Receipt.new(image: upload).image.blob
        expect(blob.byte_size).to eq(26)
        expect(blob.filename.to_s).to eq('synthetic.png')
        expect(upload.open.read).to eq(binary)
        [ 200, {}, [ 'accepted' ] ]
      end

      multipart = part.b.sub('synthetic image bytes', binary) + "--#{boundary}--\r\n"
      status, _, body = app.call(environment(multipart))

      expect(status).to eq(200)
      expect(anonymous_files.sole.closed?).to be(false)
      body.close

      expect(anonymous_files.sole.closed?).to be(true)
    ensure
      body&.close
    end

    it 'UploadedFileのclose引数を受け付け閉じた本文を再作成しない' do
      app = application do |env|
        upload = ActionDispatch::Http::UploadedFile.new(Rack::Request.new(env).POST.fetch('image'))
        upload.close
        expect(upload.tempfile.closed?).to be(true)
        expect { upload.close(true) }.not_to raise_error
        expect { upload.open }.to raise_error(IOError)
        [ 200, {}, [] ]
      end

      app.call(environment(part + "--#{boundary}--\r\n")).last.close
    end

    it '不正multipartの例外でも匿名ファイルのdescriptorを閉じる' do
      app = application { |env| Rack::Request.new(env).POST }

      expect { app.call(environment(part)) }.to raise_error(Rack::Multipart::EmptyContentError)

      expect(anonymous_files.size).to eq(1)
      expect(anonymous_files.sole.closed?).to be(true)
    end

    it '400応答の完了までは匿名ファイルを保持して完了時に閉じる' do
      app = application do |env|
        Rack::Request.new(env).POST
      rescue Rack::Multipart::EmptyContentError
        [ 400, {}, [ 'invalid upload' ] ]
      end

      status, _, body = app.call(environment(part))

      expect(status).to eq(400)
      expect(anonymous_files.sole.stat.nlink).to eq(0)
      expect(anonymous_files.sole.closed?).to be(false)
      body.close

      expect(anonymous_files.sole.closed?).to be(true)
    ensure
      body&.close
    end

    it 'multipart件数制限でparserが先に閉じてもReaperで二重closeできる' do
      allow(Rack::Utils).to receive(:multipart_file_limit).and_return(1)
      app = application { |env| Rack::Request.new(env).POST }

      expect { app.call(environment(part)) }.to raise_error(Rack::Multipart::MultipartPartLimitError)

      expect(anonymous_files.size).to eq(1)
      expect(anonymous_files.sole.closed?).to be(true)
    end

    it '匿名ファイルの作成失敗を名前付きファイルへ切り替えず伝える' do
      allow(Tempfile).to receive(:create).and_raise(Errno::EACCES)
      app = application do |env|
        Rack::Request.new(env).POST
        [ 200, {}, [] ]
      end

      expect { app.call(environment(part + "--#{boundary}--\r\n")) }.to raise_error(Errno::EACCES)
    end

    it '匿名化されていないファイルには本文を書かず閉じて拒否する' do
      file = Tempfile.new('recify-named-multipart-spec')
      files << [ file, file.path ]
      allow(Tempfile).to receive(:create).and_return(file)
      app = application do |env|
        Rack::Request.new(env).POST
        [ 200, {}, [] ]
      end

      expect { app.call(environment(part + "--#{boundary}--\r\n")) }.to raise_error(IOError)

      expect(file.closed?).to be(true)
      expect(File.size(files.sole.last)).to eq(0)
    end
  end

  it '本文を最初に読むMethodOverrideより前に既存Reaperと追跡を配置する' do
    middleware = Rails.application.middleware.map(&:klass)

    expect(middleware.index(Rack::TempfileReaper)).to be < middleware.index(described_class)
    expect(middleware.index(described_class)).to be < middleware.index(Rack::MethodOverride)
    expect(middleware.count(Rack::TempfileReaper)).to eq(1)
  end
end
