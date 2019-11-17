require 'active_job/base'
require 'active_support/core_ext/numeric/time'
require 'activejob_google_cloud_pubsub/pubsub_extension'
require 'google/cloud/pubsub'
require 'json'
require 'logger'

module ActiveJob
  module GoogleCloudPubsub
    class Worker
      using PubsubExtension
      MAX_DEDUPLICATION_ITEMS = 1000

      def initialize(queue: 'default', pubsub: Google::Cloud::Pubsub.new(timeout: 60), logger: Logger.new($stdout))
        @queue_name  = queue
        @pubsub      = pubsub
        @logger      = logger
        @deduplication_queue = Queue.new
        @deduplication_set = Set.new
      end

      def run
        subscriber = @pubsub.subscription_for(@queue_name).listen(streams: 1, threads: { callback: 1 }) do |message|
          @logger&.info "Message(#{message.message_id}) was received."
          process message
        end

        subscriber.on_error do |error|
          @logger&.error(error)
        end

        @ack_deadline = subscriber.deadline

        @quit = false
        Signal.trap(:QUIT) do
          @quit = true
        end
        Signal.trap(:TERM) do
          @quit = true
        end
        Signal.trap(:INT) do
          @quit = true
        end

        subscriber.start

        until @quit
          sleep 1
        end
        @logger&.info "Shutting down..."
        subscriber.stop.wait!
        @logger&.info "Shut down."
      end

      def ensure_subscription
        @pubsub.subscription_for @queue_name

        nil
      end

      private

      def process(message)
        return if @deduplication_set.include?(message.message_id)

        timer_opts = {
          # Extend ack deadline when only 10% of allowed time or 5 seconds are left, whichever comes first
          execution_interval: [(@ack_deadline * 0.9).round, @ack_deadline - 5].min.seconds,
          timeout_interval: 5.seconds,
          run_now: true
        }

        delay_timer = Concurrent::TimerTask.execute(timer_opts) do
          message.modify_ack_deadline! @ack_deadline
        end

        begin
          succeeded = false
          failed    = false

          ActiveJob::Base.execute JSON.parse(message.data)

          succeeded = true
        rescue StandardError
          failed = true
          raise
        ensure
          delay_timer.shutdown

          if succeeded || failed
            message.acknowledge!
            @logger&.info "Message(#{message.message_id}) was acknowledged."

            @deduplication_set.add(message.message_id)
            @deduplication_queue.push(message.message_id)
            if @deduplication_queue.length > MAX_DEDUPLICATION_ITEMS
              oldest_message_id = @deduplication_queue.pop
              @deduplication_set.delete(oldest_message_id)
            end
          else
            # terminated from outside
            message.reject!
          end
        end
      end
    end
  end
end
