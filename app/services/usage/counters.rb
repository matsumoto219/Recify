module Usage::Counters
  Entry = Struct.new(
    :key,
    :period,
    :period_start,
    :used_count,
    :used_bytes,
    :counter,
    keyword_init: true
  )

  LIMIT_KEYS = UserLimits.definitions.keys.freeze

  class << self
    def current(user:, key:, period: :day)
      normalized_period = normalize_period(period)
      period_start = period_start_for(normalized_period)
      counter = UsageCounter.find_by(user: user, key: normalize_key(key), period: normalized_period, period_start: period_start)

      entry_for(counter || build_counter(user: user, key: key, period: normalized_period, period_start: period_start))
    end

    def increment!(user:, key:, amount: 1, bytes: 0, period: :day)
      with_counter_lock(user: user, key: key, period: period) do |counter|
        counter.used_count += normalize_amount(amount)
        counter.used_bytes += normalize_bytes(bytes)
      end
    end

    def check!(user:, key:, amount: 1, limit:, period: :day)
      entry = current(user: user, key: key, period: period)
      requested = normalize_amount(amount)
      raise_if_exceeded!(key: key, limit: limit, used: entry.used_count, requested: requested)

      entry
    end

    def ensure_within_limit!(user:, key:, limit:, period: :day)
      entry = current(user: user, key: key, period: period)
      raise_if_exceeded!(key: key, limit: limit, used: entry.used_count, requested: 0)

      entry
    end

    def check_and_increment!(user:, key:, amount: 1, bytes: 0, limit:, period: :day)
      requested = normalize_amount(amount)
      byte_amount = normalize_bytes(bytes)

      with_counter_lock(user: user, key: key, period: period) do |counter|
        raise_if_exceeded!(key: key, limit: limit, used: counter.used_count, requested: requested)

        counter.used_count += requested
        counter.used_bytes += byte_amount
      end
    end

    def summary_for(user:, period: :day)
      normalized_period = normalize_period(period)
      period_start = period_start_for(normalized_period)
      counters = UsageCounter.where(
        user: user,
        key: LIMIT_KEYS,
        period: normalized_period,
        period_start: period_start
      ).index_by(&:key)

      LIMIT_KEYS.index_with do |key|
        counter = counters[key] || build_counter(user: user, key: key, period: normalized_period, period_start: period_start)
        entry_for(counter)
      end
    end

    private

    def with_counter_lock(user:, key:, period:)
      retries = 0
      normalized_key = normalize_key(key)
      normalized_period = normalize_period(period)
      period_start = period_start_for(normalized_period)

      UsageCounter.transaction do
        counter = UsageCounter.create_or_find_by!(
          user: user,
          key: normalized_key,
          period: normalized_period,
          period_start: period_start
        )
        counter.lock!
        yield counter
        counter.save!
        entry_for(counter)
      end
    rescue ActiveRecord::RecordNotUnique
      retries += 1
      retry if retries <= 1

      raise
    end

    def build_counter(user:, key:, period:, period_start:)
      UsageCounter.new(
        user: user,
        key: normalize_key(key),
        period: period,
        period_start: period_start,
        used_count: 0,
        used_bytes: 0
      )
    end

    def entry_for(counter)
      Entry.new(
        key: counter.key,
        period: counter.period,
        period_start: counter.period_start,
        used_count: counter.used_count,
        used_bytes: counter.used_bytes,
        counter: counter
      )
    end

    def raise_if_exceeded!(key:, limit:, used:, requested:)
      numeric_limit = Integer(limit)
      return if used + requested <= numeric_limit

      raise Usage::LimitExceeded.new(
        key: normalize_key(key),
        limit: numeric_limit,
        used: used,
        requested: requested
      )
    end

    def normalize_key(key)
      key.to_s.strip
    end

    def normalize_period(period)
      normalized_period = period.to_s
      raise ArgumentError, "unknown_period" unless UsageCounter::PERIODS.include?(normalized_period)

      normalized_period
    end

    def period_start_for(period)
      case period.to_s
      when "day"
        Time.zone.today.beginning_of_day
      when "minute"
        Time.current.beginning_of_minute
      else
        raise ArgumentError, "unknown_period"
      end
    end

    def normalize_amount(amount)
      integer = Integer(amount)
      raise ArgumentError, "negative_amount" if integer.negative?

      integer
    end

    def normalize_bytes(bytes)
      integer = Integer(bytes)
      raise ArgumentError, "negative_bytes" if integer.negative?

      integer
    end
  end
end
