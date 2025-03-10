# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"

require "aws-sdk-cloudwatch"

module Sidekiq::CloudWatchMetrics
  def self.enable!(**kwargs)
    Sidekiq.configure_server do |config|
      publisher = Publisher.new(**kwargs)

      # Sidekiq enterprise has a globally unique leader thread, making it
      # easier to publish the cluster-wide metrics from one place.
      if defined?(Sidekiq::Enterprise)
        config.on(:leader) do
          publisher.start
        end
      else
        # Otherwise pubishing from every node doesn't hurt, it's just wasteful
        config.on(:startup) do
          publisher.start
        end
      end

      config.on(:quiet) do
        publisher.quiet if publisher.running?
      end

      config.on(:shutdown) do
        publisher.stop if publisher.running?
      end
    end
  end

  class Publisher
    begin
      require "sidekiq/util"
      include Sidekiq::Util
    rescue LoadError
      # Sidekiq 6.5 refactored to use Sidekiq::Component
      require "sidekiq/component"
      include Sidekiq::Component
    end

    INTERVAL = 60 # seconds

    def initialize(config: Sidekiq, client: Aws::CloudWatch::Client.new, namespace: "Sidekiq", process_metrics: true, additional_dimensions: {}, external_logger: nil)
      # Sidekiq 6.5+ requires @config, which defaults to the top-level
      # `Sidekiq` module, but can be overridden when running multiple Sidekiqs.
      @config = config
      @client = client
      @namespace = namespace
      @process_metrics = process_metrics
      @additional_dimensions = additional_dimensions.map { |k, v| {name: k.to_s, value: v.to_s} }
      @external_logger = external_logger
    end

    def start
      log(:debug, "Starting Sidekiq CloudWatch Metrics Publisher")

      @done = false
      @thread = safe_thread("cloudwatch metrics publisher", &method(:run))
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    def run
      log(:info, "Started Sidekiq CloudWatch Metrics Publisher")

      # Publish stats every INTERVAL seconds, sleeping as required between runs
      now = Time.now.to_f
      tick = now
      until @stop
        # HERE: This is pretty noisy so I won't use Publisher#log
        logger.debug { "Publishing Sidekiq CloudWatch Metrics" }
        publish

        now = Time.now.to_f
        tick = [tick + INTERVAL, now].max
        sleep(tick - now) if tick > now
      end

      log(:debug, "Stopped Sidekiq CloudWatch Metrics Publisher")
    end

    def publish
      now = Time.now
      stats = Sidekiq::Stats.new
      processes = Sidekiq::ProcessSet.new.to_enum(:each).to_a
      queues = stats.queues

      metrics = [
        {
          metric_name: "ProcessedJobs",
          timestamp: now,
          value: stats.processed,
          unit: "Count",
        },
        {
          metric_name: "FailedJobs",
          timestamp: now,
          value: stats.failed,
          unit: "Count",
        },
        {
          metric_name: "EnqueuedJobs",
          timestamp: now,
          value: stats.enqueued,
          unit: "Count",
        },
        {
          metric_name: "ScheduledJobs",
          timestamp: now,
          value: stats.scheduled_size,
          unit: "Count",
        },
        {
          metric_name: "RetryJobs",
          timestamp: now,
          value: stats.retry_size,
          unit: "Count",
        },
        {
          metric_name: "DeadJobs",
          timestamp: now,
          value: stats.dead_size,
          unit: "Count",
        },
        {
          metric_name: "Workers",
          timestamp: now,
          value: stats.workers_size,
          unit: "Count",
        },
        {
          metric_name: "Processes",
          timestamp: now,
          value: stats.processes_size,
          unit: "Count",
        },
        {
          metric_name: "DefaultQueueLatency",
          timestamp: now,
          value: stats.default_queue_latency,
          unit: "Seconds",
        },
        {
          metric_name: "Capacity",
          timestamp: now,
          value: calculate_capacity(processes),
          unit: "Count",
        },
      ]

      utilization = calculate_utilization(processes) * 100.0

      unless utilization.nan?
        metrics << {
          metric_name: "Utilization",
          timestamp: now,
          value: utilization,
          unit: "Percent",
        }
      end

      processes.group_by do |process|
        process["tag"]
      end.each do |(tag, tag_processes)|
        next if tag.nil?

        tag_utilization = calculate_utilization(tag_processes) * 100.0

        unless tag_utilization.nan?
          metrics << {
            metric_name: "Utilization",
            dimensions: [{name: "Tag", value: tag}],
            timestamp: now,
            value: tag_utilization,
            unit: "Percent",
          }
        end
      end

      if @process_metrics
        processes.each do |process|
          process_utilization = process["busy"] / process["concurrency"].to_f * 100.0

          unless process_utilization.nan?
            process_dimensions = [{name: "Hostname", value: process["hostname"]}]

            if process["tag"]
              process_dimensions << {name: "Tag", value: process["tag"]}
            end

            metrics << {
              metric_name: "Utilization",
              dimensions: process_dimensions,
              timestamp: now,
              value: process_utilization,
              unit: "Percent",
            }
          end
        end
      end

      queues.each do |(queue_name, queue_size)|
        metrics << {
          metric_name: "QueueSize",
          dimensions: [{name: "QueueName", value: queue_name}],
          timestamp: now,
          value: queue_size,
          unit: "Count",
        }

        queue_latency = Sidekiq::Queue.new(queue_name).latency

        metrics << {
          metric_name: "QueueLatency",
          dimensions: [{name: "QueueName", value: queue_name}],
          timestamp: now,
          value: queue_latency,
          unit: "Seconds",
        }
      end

      unless @additional_dimensions.empty?
        metrics = metrics.each do |metric|
          metric[:dimensions] = (metric[:dimensions] || []) + @additional_dimensions
        end
      end

      # We can only put 20 metrics at a time
      metrics.each_slice(20) do |some_metrics|
        retry_count = 0

        begin
          @client.put_metric_data(
            namespace: @namespace,
            metric_data: some_metrics,
          )
        rescue Aws::CloudWatch::Errors::ExpiredToken => e
          if retry_count < 3
            retry_count += 1
            log(:warn, "#{@client.class} security token expired (expiration: #{@client.config.credentials.expiration}). Refreshing client and retrying... (attempt #{retry_count})")
            refresh_client_credentials!
            retry
          else
            log(:error, "Exceeded retry limit for #{@client.class} security token refresh. Error: #{e.message}")
            raise # Re-raise the error after exceeding the retry limit
          end
        end
      end
    end

    def refresh_client_credentials!
      log(:info, "Refreshing #{@client.class} credentials...")
      @client.credentials.refresh!
    end

    # Returns the total number of workers across all processes
    private def calculate_capacity(processes)
      processes.map do |process|
        process["concurrency"]
      end.sum
    end

    # Returns busy / concurrency averaged across processes (for scaling)
    # Avoid considering processes not yet running any threads
    private def calculate_utilization(processes)
      process_utilizations = processes.map do |process|
        process["busy"] / process["concurrency"].to_f
      end.reject(&:nan?)

      process_utilizations.sum / process_utilizations.size.to_f
    end

    def quiet
      log(:debug, "Quieting Sidekiq CloudWatch Metrics Publisher")
      @stop = true
    end

    def stop
      log(:debug, "Stopping Sidekiq CloudWatch Metrics Publisher")
      @stop = true
      @thread.wakeup
      @thread.join
    rescue ThreadError
      # Don't raise if thread is already dead.
      nil
    end

    private

    def log(level, message)
      logger.send(level) { message }
      @external_logger.send(level, :aws_credentials, message) if @external_logger
    end
  end
end
