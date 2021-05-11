require 'fluent/plugin/compressable'
require 'fluent/plugin/output'
require 'fluent/plugin/gcloud_pubsub/client'
require 'fluent/plugin_helper/inject'

module Fluent::Plugin
  class GcloudPubSubOutput < Output
    include Fluent::Plugin::Compressable
    include Fluent::PluginHelper::Inject

    Fluent::Plugin.register_output('gcloud_pubsub', self)

    helpers :compat_parameters, :formatter

    DEFAULT_BUFFER_TYPE = "memory"
    DEFAULT_FORMATTER_TYPE = "json"

    desc 'Set your GCP project.'
    config_param :project,            :string,  :default => nil
    desc 'Set your credential file path.'
    config_param :key,                :string,  :default => nil
    desc 'Set topic name to publish.'
    config_param :topic,              :string
    desc "Set your dest GCP project if publishing cross project"
    config_param :dest_project,       :string,  :default => nil
    desc "If set to `true`, specified topic will be created when it doesn't exist."
    config_param :autocreate_topic,   :bool,    :default => false
    desc 'Publishing messages count per request to Cloud Pub/Sub.'
    config_param :max_messages,       :integer, :default => 1000
    desc 'Publishing messages bytesize per request to Cloud Pub/Sub.'
    config_param :max_total_size,     :integer, :default => 9800000  # 9.8MB
    desc 'Limit bytesize per message.'
    config_param :max_message_size,   :integer, :default => 4000000  # 4MB
    desc 'Publishing the set field as an attribute'
    config_param :attribute_keys,     :array,   :default => []
    desc 'Set service endpoint'
    config_param :endpoint, :string, :default => nil
    desc 'Compress messages'
    config_param :compression, :string, :default => nil
    desc 'Set default emulator_host to use in publish requests'
    config_param :emulator_host, :string, :default => nil

    config_section :buffer do
      config_set_default :@type, DEFAULT_BUFFER_TYPE
    end

    config_section :format do
      config_set_default :@type, DEFAULT_FORMATTER_TYPE
    end

    def configure(conf)
      compat_parameters_convert(conf, :buffer, :formatter)
      super
      placeholder_validate!(:topic, @topic)
      @formatter = formatter_create
      @compress = if @compression == 'gzip'
                    method(:gzip_compress)
                  else
                    method(:no_compress)
                  end
    end

    def start
      super
      @publisher = Fluent::GcloudPubSub::Publisher.new @project, @key, @autocreate_topic, @dest_project, @endpoint, @emulator_host
    end

    def format(tag, time, record)
      record = inject_values_to_record(tag, time, record)
      attributes = {}
      @attribute_keys.each do |key|
        attributes[key] = record.delete(key)
      end
      [@compress.call(@formatter.format(tag, time, record)), attributes].to_msgpack
    end

    def formatted_to_msgpack_binary?
      true
    end

    def multi_workers_ready?
      true
    end

    def write(chunk)
      topic = extract_placeholders(@topic, chunk.metadata)

      messages = []
      size = 0

      chunk.msgpack_each do |msg, attr|
        msg = Fluent::GcloudPubSub::Message.new(msg, attr)
        if msg.bytesize > @max_message_size
          log.warn 'Drop a message because its size exceeds `max_message_size`', size: msg.bytesize
          next
        end
        if messages.length + 1 > @max_messages || size + msg.bytesize > @max_total_size
          publish(topic, messages)
          messages = []
          size = 0
        end
        messages << msg
        size += msg.bytesize
      end

      if messages.length > 0
        publish(topic, messages)
      end
    rescue Fluent::GcloudPubSub::RetryableError => ex
      log.warn "Retryable error occurs. Fluentd will retry.", error_message: ex.to_s, error_class: ex.class.to_s
      raise ex
    rescue => ex
      log.error "unexpected error", error_message: ex.to_s, error_class: ex.class.to_s
      log.error_backtrace
      raise ex
    end

    private

    def publish(topic, messages)
      log.debug "send message topic:#{topic} length:#{messages.length} size:#{messages.map(&:bytesize).inject(:+)}"
      @publisher.publish(topic, messages)
    end

    def gzip_compress(message)
      compress message
    end

    def no_compress(message)
      message
    end
  end
end
