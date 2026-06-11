require 'rails_helper'

RSpec.describe Admin::DatabaseStatusSnapshot do
  describe '.call' do
    it 'primary DB接続、migration最新、DB時刻を返す' do
      result = described_class.new(
        connection: instance_double(
          ActiveRecord::ConnectionAdapters::AbstractAdapter,
          select_value: nil
        ).tap { |connection|
          allow(connection).to receive(:select_value).with("SELECT 1").and_return(1)
          allow(connection).to receive(:select_value).with("SELECT CURRENT_TIMESTAMP").and_return("2026-06-12 10:30:00 +0900")
        },
        migration_checker: class_double(ActiveRecord::Migration, check_all_pending!: nil)
      ).call

      aggregate_failures do
        expect(result).to include(
          primary: "ok",
          migration: "current"
        )
        expect(result[:database_time]).to eq(Time.zone.parse("2026-06-12 10:30:00 +0900"))
      end
    end

    it '未適用migrationがある場合はpendingを返す' do
      migration_checker = class_double(ActiveRecord::Migration)
      allow(migration_checker).to receive(:check_all_pending!).and_raise(ActiveRecord::PendingMigrationError, "pending")

      result = described_class.new(
        connection: connection_double,
        migration_checker: migration_checker
      ).call

      expect(result).to include(primary: "ok", migration: "pending")
    end

    it 'DB接続確認に失敗しても例外を外へ出さずunavailableを返す' do
      connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
      allow(connection).to receive(:select_value).with("SELECT 1").and_raise(ActiveRecord::StatementInvalid, "database unavailable")

      result = described_class.new(connection: connection).call

      expect(result).to eq(
        primary: "unavailable",
        migration: "unavailable",
        database_time: nil
      )
    end

    it 'migration確認だけ失敗した場合はprimary正常のままmigrationをunavailableにする' do
      migration_checker = class_double(ActiveRecord::Migration)
      allow(migration_checker).to receive(:check_all_pending!).and_raise(StandardError, "migration check failed")

      result = described_class.new(
        connection: connection_double,
        migration_checker: migration_checker
      ).call

      aggregate_failures do
        expect(result[:primary]).to eq("ok")
        expect(result[:migration]).to eq("unavailable")
        expect(result[:database_time]).to be_present
      end
    end
  end

  def connection_double
    instance_double(
      ActiveRecord::ConnectionAdapters::AbstractAdapter,
      select_value: nil
    ).tap do |connection|
      allow(connection).to receive(:select_value).with("SELECT 1").and_return(1)
      allow(connection).to receive(:select_value).with("SELECT CURRENT_TIMESTAMP").and_return(Time.zone.parse("2026-06-12 10:30:00"))
    end
  end
end
