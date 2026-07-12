module Admin
  class DatabaseStatusSnapshot
    class << self
      def call
        new.call
      end
    end

    def initialize(connection: ActiveRecord::Base.connection, migration_checker: ActiveRecord::Migration)
      @connection = connection
      @migration_checker = migration_checker
    end

    def call
      return unavailable_snapshot unless primary_available?

      {
        primary: "ok",
        migration: migration_state,
        database_time: database_time
      }
    rescue StandardError
      unavailable_snapshot
    end

    private

    attr_reader :connection, :migration_checker

    def primary_available?
      connection.select_value("SELECT 1").to_i == 1
    rescue StandardError
      false
    end

    def migration_state
      migration_checker.check_all_pending!
      "current"
    rescue ActiveRecord::PendingMigrationError
      "pending"
    rescue StandardError
      "unavailable"
    end

    def database_time
      value = connection.select_value("SELECT CURRENT_TIMESTAMP")
      normalize_time(value)
    rescue StandardError
      nil
    end

    def normalize_time(value)
      case value
      when Time, DateTime
        value.in_time_zone
      else
        Time.zone.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def unavailable_snapshot
      {
        primary: "unavailable",
        migration: "unavailable",
        database_time: nil
      }
    end
  end
end
