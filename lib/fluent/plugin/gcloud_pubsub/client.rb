require 'google/cloud/pubsub'

module Fluent
  module GcloudPubSub
    class Error < StandardError
    end
    class RetryableError < Error
    end

    class Message
      attr_reader :message, :attributes
      def initialize(message, attributes={})
        @message = message
        @attributes = attributes
      end

      def bytesize()
        attr_size = 0
        @attributes.each do |key, val|
          attr_size += key.bytesize + val.bytesize
        end
        @message.bytesize + attr_size
      end
    end

    class Publisher
      def initialize(project, key, autocreate_topic, dest_project, endpoint)
        @pubsub = Google::Cloud::Pubsub.new project_id: project, credentials: key, endpoint: endpoint, emulator_host: emulator_host
        @autocreate_topic = autocreate_topic
        @dest_project = dest_project
        @topics = {}
      end

      def topic(topic_name)
        return @topics[topic_name] if @topics.has_key? topic_name

        if @dest_project.nil?
          client = @pubsub.topic topic_name
          if client.nil? && @autocreate_topic
            client = @pubsub.create_topic topic_name
          end
        else
          client = @pubsub.topic topic_name, project: @dest_project
        end
        if client.nil?
          raise Error.new "topic:#{topic_name} does not exist."
        end

        @topics[topic_name] = client
        client
      end

      def publish(topic_name, messages)
        topic(topic_name).publish do |batch|
          messages.each do |m|
            batch.publish m.message, m.attributes
          end
        end
      rescue Google::Cloud::UnavailableError, Google::Cloud::DeadlineExceededError, Google::Cloud::InternalError => ex
        raise RetryableError.new "Google api returns error:#{ex.class.to_s} message:#{ex.to_s}"
      end
    end

    class Subscriber
      def initialize(project, key, topic_name, subscription_name)
        pubsub = Google::Cloud::Pubsub.new project_id: project, credentials: key
        if topic_name.nil?
          @client = pubsub.subscription subscription_name
        else
          topic = pubsub.topic topic_name
          @client = topic.subscription subscription_name
        end
        raise Error.new "subscription:#{subscription_name} does not exist." if @client.nil?
      end

      def pull(immediate, max)
        @client.pull immediate: immediate, max: max
      rescue Google::Cloud::UnavailableError, Google::Cloud::DeadlineExceededError, Google::Cloud::InternalError => ex
        raise RetryableError.new "Google pull api returns error:#{ex.class.to_s} message:#{ex.to_s}"
      end

      def acknowledge(messages)
        @client.acknowledge messages
      rescue Google::Cloud::UnavailableError, Google::Cloud::DeadlineExceededError, Google::Cloud::InternalError => ex
        raise RetryableError.new "Google acknowledge api returns error:#{ex.class.to_s} message:#{ex.to_s}"
      end
    end
  end
end
