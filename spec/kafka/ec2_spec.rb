require "spec_helper"

RSpec.describe Kafka::EC2 do
  it "has a version number" do
    expect(Kafka::EC2::VERSION).not_to be nil
  end

  describe ".with_assignment_strategy_factory" do
    let(:kafka) { Kafka.new(["localhost:9092"], client_id: "net.abicky.ruby-kafka-ec2") }
    let(:kafka_topic) { ENV["KAFKA_TOPIC"] }
    let(:key_prefix) { Time.now.to_i.to_s }
    let(:partition_count) { 3 }

    before do
      WebMock.disable_net_connect!(allow_localhost: true)
      stub_request(:get, "169.254.169.254/latest/meta-data/instance-id").to_return(body: "i-00000000000000000")
      stub_request(:get, "169.254.169.254/latest/meta-data/instance-type").to_return(body: "c5.xlarge")
      stub_request(:get, "169.254.169.254/latest/meta-data/placement/availability-zone").to_return(body: "ap-northeast-1a")

      unless kafka.topics.include?(kafka_topic) # Don't use kafka.has_topic(kafka_topic) because it creates the topic
        kafka.create_topic(kafka_topic, num_partitions: partition_count)
      end

      partition_count.times do |i|
        kafka.deliver_message(i.to_s, topic: kafka_topic, key: "#{key_prefix}_#{i}", partition: i)
      end
    end

    it "consumers messages correctly", kafka: true do
      assignment_strategy_factory = Kafka::EC2::MixedInstanceAssignmentStrategyFactory.new(
        instance_family_weights: {
          "r4" => 1,
          "r5" => 1.08,
          "m5" => 1.13,
          "c5" => 1.25,
        },
        availability_zone_weights: ->() {
          {
            "ap-northeast-1a" => 1,
            "ap-northeast-1c" => 0.9,
          }
        },
      )

      expect(assignment_strategy_factory).to receive(:create).and_wrap_original do |m, *args, **kwargs|
        strategy = m.call(*args, **kwargs)
        expect(strategy).to receive(:assign).and_call_original
        strategy
      end

      require "concurrent/map" # cf. https://github.com/zendesk/ruby-kafka/pull/835
      consumer = Kafka::EC2.with_assignment_strategy_factory(assignment_strategy_factory) do
        kafka.consumer(group_id: "net.abicky.ruby-kafka-ec2.rspec")
      end
      consumer.subscribe(kafka_topic)

      received_messages = []
      consumer.each_message do |message|
        received_messages << message.value if message.key.start_with?(key_prefix)
        consumer.stop if received_messages.size == partition_count
      end
      expect(received_messages).to match_array(partition_count.times.map(&:to_s))
    end
  end
end
