# frozen_string_literal: true

require "redis_client"
require "redis_client/decorator"

module Sidekiq
  class RedisClientAdapter
    BaseError = RedisClient::Error
    CommandError = RedisClient::CommandError

    # You can add/remove items or clear the whole thing if you don't want deprecation warnings.
    DEPRECATED_COMMANDS = %i[rpoplpush zrangebyscore zrevrange zrevrangebyscore getset hmset setex setnx]

    module CompatMethods
      def info
        @client.call("INFO") { |i| i.lines(chomp: true).map { |l| l.split(":", 2) }.select { |l| l.size == 2 }.to_h }
      end

      def evalsha(sha, keys, argv)
        @client.call("EVALSHA", sha, keys.size, *keys, *argv)
      end

      private

      # this allows us to use methods like `conn.hmset(...)` instead of having to use
      # redis-client's native `conn.call("hmset", ...)`
      def method_missing(*args, &block)
        warn("[#5788] Redis has deprecated the `#{args.first}`command, called at #{caller(1..1)}") if DEPRECATED_COMMANDS.include?(args.first)
        @client.call(*args, *block)
      end
      ruby2_keywords :method_missing if respond_to?(:ruby2_keywords, true)

      def respond_to_missing?(name, include_private = false)
        super # Appease the linter. We can't tell what is a valid command.
      end
    end

    CompatClient = RedisClient::Decorator.create(CompatMethods)

    class CompatClient
      def config
        @client.config
      end
    end

    def initialize(options)
      opts = client_opts(options)
      @config = if opts.key?(:sentinels)
        RedisClient.sentinel(**opts)
      else
        RedisClient.config(**opts)
      end
    end

    def new_client
      CompatClient.new(@config.new_client)
    end

    private

    def client_opts(options)
      opts = options.dup

      if opts[:namespace]
        raise ArgumentError, "Your Redis configuration uses the namespace '#{opts[:namespace]}' but this feature isn't supported by redis-client. " \
          "Either use the redis adapter or remove the namespace."
      end

      opts.delete(:size)
      opts.delete(:pool_timeout)

      if opts[:network_timeout]
        opts[:timeout] = opts[:network_timeout]
        opts.delete(:network_timeout)
      end

      if opts[:driver]
        opts[:driver] = opts[:driver].to_sym
      end

      opts[:name] = opts.delete(:master_name) if opts.key?(:master_name)
      opts[:role] = opts[:role].to_sym if opts.key?(:role)
      opts.delete(:url) if opts.key?(:sentinels)

      # Issue #3303, redis-rb will silently retry an operation.
      # This can lead to duplicate jobs if Sidekiq::Client's LPUSH
      # is performed twice but I believe this is much, much rarer
      # than the reconnect silently fixing a problem; we keep it
      # on by default.
      opts[:reconnect_attempts] ||= 1

      opts
    end
  end
end
