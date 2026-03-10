module Api::V1
  class PricingService < BaseService
    CACHE_TTL = 5.minutes

    VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
    VALID_HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
    VALID_ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze

    ALL_COMBINATIONS = VALID_PERIODS.product(VALID_HOTELS, VALID_ROOMS)
                                    .map { |p, h, r| { period: p, hotel: h, room: r } }.freeze

    FETCH_MUTEX = Mutex.new

    attr_reader :error_status

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel  = hotel
      @room   = room
    end

    def run
      cache_key = "pricing/#{@period}/#{@hotel}/#{@room}"

      cached = Rails.cache.read(cache_key)
      if cached
        Rails.logger.info("[pricing] cache=hit period=#{@period} hotel=#{@hotel} room=#{@room}")
        @result = cached
        return
      end

      FETCH_MUTEX.synchronize do
        # Re-check after acquiring lock — another thread may have already fetched
        if Rails.cache.read(cache_key)
          Rails.logger.info("[pricing] cache=hit period=#{@period} hotel=#{@hotel} room=#{@room} (post-lock)")
        else
          Rails.logger.info("[pricing] cache=miss period=#{@period} hotel=#{@hotel} room=#{@room} — fetching all combinations")
          fetch_and_cache_all
        end
      end
      return unless valid?

      @result = Rails.cache.read(cache_key)
      if @result.nil?
        @error_status = :bad_gateway
        errors << 'Rate not found in upstream response'
      end
    end

    private

    def fetch_and_cache_all
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = RateApiClient.get_rates(ALL_COMBINATIONS)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      if response.success?
        parsed = JSON.parse(response.body)
        parsed['rates']&.each do |r|
          key = "pricing/#{r['period']}/#{r['hotel']}/#{r['room']}"
          Rails.cache.write(key, r['rate'].to_i, expires_in: CACHE_TTL)
        end
        Rails.logger.info("[pricing] upstream=ok duration_ms=#{duration_ms} cached=#{parsed['rates']&.size || 0}")
      else
        @error_status = :bad_gateway
        parsed_error = JSON.parse(response.body) rescue {}
        error_msg = parsed_error['error'] || 'Rate API returned an error'
        Rails.logger.error("[pricing] upstream=error duration_ms=#{duration_ms} message=#{error_msg}")
        errors << error_msg
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      @error_status = :service_unavailable
      Rails.logger.error("[pricing] upstream=timeout error=#{e.class}")
      errors << 'Rate API timed out'
    rescue => e
      @error_status = :bad_gateway
      Rails.logger.error("[pricing] upstream=error error=#{e.class} message=#{e.message}")
      errors << 'Unexpected error fetching rate'
    end
  end
end
