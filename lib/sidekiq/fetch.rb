# frozen_string_literal: true

require "sidekiq"
require "sidekiq/component"
require "sidekiq/capsule"

module Sidekiq # :nodoc:
  class BasicFetch
    include Sidekiq::Component
    # We want the fetch operation to timeout every few seconds so the thread
    # can check if the process is shutting down.
    TIMEOUT = 2

    UnitOfWork = Struct.new(:queue, :job, :config) {
      def acknowledge
        # nothing to do
      end

      def queue_name
        queue.delete_prefix("queue:")
      end

      def requeue
        config.redis do |conn|
          conn.rpush(queue, job)
        end
      end
    }

    def initialize(cap)
      raise ArgumentError, "missing queue list" unless cap.queues
      @config = cap
      @strictly_ordered_queues = cap.mode == :strict
      @queues = config.queues.map { |q| "queue:#{q}" }
      @queues.uniq! if @strictly_ordered_queues

      @queues_names = config.queues.map(&:to_s).join(',')
      @next_log = Time.now
    end

    def retrieve_work
      qs = queues_cmd
      # 4825 Sidekiq Pro with all queues paused will return an
      # empty set of queues
      if qs.size <= 0
        sleep(TIMEOUT)
        return nil
      end

      if Time.now > @next_log
        @next_log = Time.now + 15.seconds

        if @queues_names == 'webhooks'
          logger.info "Fetching from #{@queues_names}"
          queue_size = redis { |conn| conn.llen "queue:webhooks" }
          logger.info "Webhooks queue size: #{queue_size}"
        end
      end

      queue, job = redis { |conn| conn.blocking_call(conn.read_timeout + TIMEOUT, "brpop", *qs, TIMEOUT) }
      UnitOfWork.new(queue, job, config) if queue
    end

    def bulk_requeue(inprogress)
      return if inprogress.empty?

      logger.debug { "Re-queueing terminated jobs" }
      jobs_to_requeue = {}
      inprogress.each do |unit_of_work|
        jobs_to_requeue[unit_of_work.queue] ||= []
        jobs_to_requeue[unit_of_work.queue] << unit_of_work.job
      end

      redis do |conn|
        conn.pipelined do |pipeline|
          jobs_to_requeue.each do |queue, jobs|
            pipeline.rpush(queue, jobs)
          end
        end
      end
      logger.info("Pushed #{inprogress.size} jobs back to Redis")
    rescue => ex
      logger.warn("Failed to requeue #{inprogress.size} jobs: #{ex.message}")
    end

    # Creating the Redis#brpop command takes into account any
    # configured queue weights. By default Redis#brpop returns
    # data from the first queue that has pending elements. We
    # recreate the queue command each time we invoke Redis#brpop
    # to honor weights and avoid queue starvation.
    def queues_cmd
      if @strictly_ordered_queues
        @queues
      else
        permute = @queues.shuffle
        permute.uniq!
        permute
      end
    end
  end
end
