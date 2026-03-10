module Api::V1
  class PricingService < BaseService
    CACHE_TTL = 5.minutes

    VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
    VALID_HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
    VALID_ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze

    ALL_COMBINATIONS = VALID_PERIODS.product(VALID_HOTELS, VALID_ROOMS)
                                    .map { |p, h, r| { period: p, hotel: h, room: r } }.freeze

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
        @result = cached
        return
      end

      fetch_and_cache_all
      @result = Rails.cache.read(cache_key)

      if @result.nil?
        @error_status = :bad_gateway
        errors << 'Rate not found in upstream response'
      end
    end

    private

    def fetch_and_cache_all
      response = RateApiClient.get_rates(ALL_COMBINATIONS)

      if response.success?
        parsed = JSON.parse(response.body)
        parsed['rates']&.each do |r|
          key = "pricing/#{r['period']}/#{r['hotel']}/#{r['room']}"
          Rails.cache.write(key, r['rate'].to_i, expires_in: CACHE_TTL)
        end
      else
        @error_status = :bad_gateway
        parsed_error = JSON.parse(response.body) rescue {}
        errors << (parsed_error['error'] || 'Rate API returned an error')
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      @error_status = :service_unavailable
      errors << 'Rate API timed out'
    rescue => e
      @error_status = :bad_gateway
      errors << 'Unexpected error fetching rate'
    end
  end
end
