require "spec_helper"
require "tmpdir"
require "timeout"
require_relative "../../../app/services/storage"
require_relative "../../../app/services/storage/upload_lock"

RSpec.describe Storage::UploadLock do
  around do |example|
    Dir.mktmpdir("recify-upload-lock-spec") do |directory|
      @directory = directory
      example.run
    end
  end

  before do
    disk_service = Class.new { attr_accessor :root }
    stub_const("ActiveStorage::Service::DiskService", disk_service)
    blob_class = Class.new do
      class << self
        attr_accessor :service, :connection
      end
    end
    stub_const("ActiveStorage::Blob", blob_class)
    service = disk_service.new
    service.root = @directory
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)
  end

  def with_child_holding_lock(key: "same-operation", abrupt_exit: false)
    ready_reader, ready_writer = IO.pipe
    release_reader, release_writer = IO.pipe
    pid = fork do
      ready_reader.close
      release_writer.close
      described_class.call(key: key, namespace: "images") do
        ready_writer.write("1")
        ready_writer.close
        release_reader.read(1)
        exit! 0 if abrupt_exit
      end
      exit! 0
    rescue StandardError
      exit! 1
    end
    ready_writer.close
    release_reader.close
    expect(Timeout.timeout(5) { ready_reader.read(1) }).to eq("1")
    yield release_writer
  ensure
    release_writer&.close unless release_writer&.closed?
    ready_reader&.close unless ready_reader&.closed?
    ready_writer&.close unless ready_writer&.closed?
    release_reader&.close unless release_reader&.closed?
    if pid
      begin
        _, status = Timeout.timeout(5) { Process.wait2(pid) }
        expect(status.success?).to be(true)
      rescue Timeout::Error
        Process.kill("KILL", pid)
        Process.wait(pid)
        raise
      end
    end
  end

  it "別processが保持する同じ操作lockは待たずにskipする" do
    entered = false

    with_child_holding_lock do
      result = Timeout.timeout(1) do
        described_class.call(key: "same-operation", namespace: "images") { entered = true }
      end
      expect(result).to be_nil
    end

    expect(entered).to be(false)
    expect(described_class.call(key: "same-operation", namespace: "images") { :acquired }).to eq(:acquired)
  end

  it "writerがensureを実行せずprocess終了してもOSがlockを解放する" do
    with_child_holding_lock(abrupt_exit: true) do
      expect(described_class.call(key: "same-operation", namespace: "images") { :unexpected }).to be_nil
    end

    expect(described_class.call(key: "same-operation", namespace: "images") { :acquired }).to eq(:acquired)
  end

  it "database接続が利用不能でもfile lockの保持と再取得にDBを使用しない" do
    expect(ActiveStorage::Blob).not_to receive(:connection)
    stub_const("ActiveRecord::Base", Class.new do
      def self.connection
        raise "database unavailable"
      end
    end)
    expect(ActiveRecord::Base).not_to receive(:connection)

    with_child_holding_lock do
      expect(described_class.call(key: "same-operation", namespace: "images") { :unexpected }).to be_nil
    end

    expect(described_class.call(key: "same-operation", namespace: "images") { :acquired }).to eq(:acquired)
  end

  it "例外でblockを抜けても次のwriterが同じinodeのlockを取得できる" do
    expect do
      described_class.call(key: "same-operation", namespace: "images") { raise IOError, "synthetic failure" }
    end.to raise_error(IOError, "synthetic failure")

    files = Dir.glob(File.join(@directory, ".upload-locks", "images", "*"))
    expect(files.size).to eq(1)
    path = files.first
    inode = File.stat(path).ino
    expect(described_class.call(key: "same-operation", namespace: "images") { :acquired }).to eq(:acquired)
    expect(File.stat(path).ino).to eq(inode)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "異なる操作が増えてもlock file数をnamespaceごとの固定上限内に保つ" do
    1024.times do |index|
      described_class.call(key: "operation-#{index}", namespace: "images") { true }
    end
    files = Dir.glob(File.join(@directory, ".upload-locks", "images", "*"))

    expect(files.size).to be_between(1, 256)
    expect(files.map { |path| File.basename(path) }).to all(match(/\A\d+\z/))
    expect(Dir.glob(File.join(@directory, ".upload-locks", "**", "*"))).not_to include(a_string_including("operation-"))
  end

  it "受付と画像のnamespaceが同じkeyでも互いを誤ってlockしない" do
    with_child_holding_lock do
      expect(described_class.call(key: "same-operation", namespace: "registrations") { :acquired }).to eq(:acquired)
    end
  end

  it "未対応storageではblockもlock file作成も行わない" do
    allow(ActiveStorage::Blob).to receive(:service).and_return(Object.new)
    entered = false

    expect do
      described_class.call(key: "same-operation", namespace: "images") { entered = true }
    end.to raise_error(ArgumentError, "unsupported upload storage")
    expect(entered).to be(false)
    expect(Dir.children(@directory)).to be_empty
  end

  it "未許可namespaceをpathに使わない" do
    expect do
      described_class.call(key: "same-operation", namespace: "../other") { raise "unexpected" }
    end.to raise_error(ArgumentError, "unsupported upload lock")

    expect(Dir.children(@directory)).to be_empty
  end
end
