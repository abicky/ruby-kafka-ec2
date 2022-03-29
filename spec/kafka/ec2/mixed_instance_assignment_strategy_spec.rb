require "spec_helper"
require "kafka/consumer_group/assignor"
require "kafka/protocol/join_group_response"

RSpec.describe Kafka::EC2::MixedInstanceAssignmentStrategy do
  let(:cluster) do
    instance_double("Kafka::Cluster")
  end

  describe "behavior as an assignor" do
    let(:kafka) { Kafka.new(["localhost:9092"], client_id: "net.abicky.ruby-kafka-ec2") }
    let(:kafka_topic) { ENV["KAFKA_TOPIC"] }
    let(:key_prefix) { Time.now.to_i.to_s }
    let(:partition_count) { 3 }

    let(:instance_id) { "i-00000000000000000" }
    let(:instance_type) { "c5.xlarge" }
    let(:availability_zone) { "ap-northeast-1a" }

    before do
      WebMock.disable_net_connect!(allow_localhost: true)
      stub_request(:get, "169.254.169.254/latest/meta-data/instance-id").to_return(body: instance_id)
      stub_request(:get, "169.254.169.254/latest/meta-data/instance-type").to_return(body: instance_type)
      stub_request(:get, "169.254.169.254/latest/meta-data/placement/availability-zone").to_return(body: availability_zone)

      unless kafka.topics.include?(kafka_topic) # Don't use kafka.has_topic(kafka_topic) because it creates the topic
        kafka.create_topic(kafka_topic, num_partitions: partition_count)
      end

      partition_count.times do |i|
        kafka.deliver_message(i.to_s, topic: kafka_topic, key: "#{key_prefix}_#{i}", partition: i)
      end
    end

    it "consumes messages correctly", kafka: true do
      assignment_strategy = Kafka::EC2::MixedInstanceAssignmentStrategy.new(
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
      expect(assignment_strategy).to receive(:call).and_wrap_original do |m, cluster:, members:, partitions:|
        expect(members.values.first.user_data).to eq [instance_id, instance_type, availability_zone].join(",")
        m.call(cluster: cluster, members: members, partitions: partitions)
      end

      consumer = kafka.consumer(group_id: "net.abicky.ruby-kafka-ec2.rspec", assignment_strategy: assignment_strategy)
      consumer.subscribe(kafka_topic)

      received_messages = []
      consumer.each_message do |message|
        received_messages << message.value if message.key.start_with?(key_prefix)
        consumer.stop if received_messages.size == partition_count
      end
      expect(received_messages).to match_array(partition_count.times.map(&:to_s))
    end
  end

  describe "#call" do
    subject(:member_id_to_partitions) { strategy.call(cluster: cluster, members: members, partitions: partitions) }

    let(:members) do
      member_id_to_userdata.transform_values do |v|
        Kafka::Protocol::JoinGroupResponse::Metadata.new(0, "topic", v)
      end
    end

    let(:partitions) do
      partition_ids.map { |id| Kafka::ConsumerGroup::Assignor::Partition.new("topic", id) }
    end

    context "with instance_family_weights and availability_zone_weights" do
      let(:strategy) do
        described_class.new(
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
      end

      context "with various instances" do
        let(:partition_ids) { (0 .. 500).to_a }
        let(:member_id_to_userdata) do
          {
            # Instances which have two members
            "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
            "0001-m5-a-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
            "0002-r5-a-0000" => "i-00000000000000002,r5.xlarge,ap-northeast-1a",
            "0003-r4-a-0000" => "i-00000000000000003,r4.xlarge,ap-northeast-1a",
            "0004-c5-c-0000" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
            "0005-m5-c-0000" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
            "0006-r5-c-0000" => "i-00000000000000006,r5.xlarge,ap-northeast-1c",
            "0007-r4-c-0000" => "i-00000000000000007,r4.xlarge,ap-northeast-1c",
            "0000-c5-a-0001" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
            "0001-m5-a-0001" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
            "0002-r5-a-0001" => "i-00000000000000002,r5.xlarge,ap-northeast-1a",
            "0003-r4-a-0001" => "i-00000000000000003,r4.xlarge,ap-northeast-1a",
            "0004-c5-c-0001" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
            "0005-m5-c-0001" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
            "0006-r5-c-0001" => "i-00000000000000006,r5.xlarge,ap-northeast-1c",
            "0007-r4-c-0001" => "i-00000000000000007,r4.xlarge,ap-northeast-1c",
            # Instances which have only one member
            "1000-c5-a-0000" => "i-00000000000001000,c5.xlarge,ap-northeast-1a",
            "1001-r4-a-0000" => "i-00000000000001001,r4.xlarge,ap-northeast-1a",
          }
        end

        let(:expected_partition_count) do
          {
            "0000-c5-a-0000" => 33,
            "0001-m5-a-0000" => 30,
            "0002-r5-a-0000" => 28,
            "0003-r4-a-0000" => 26,
            "0004-c5-c-0000" => 29,
            "0005-m5-c-0000" => 27,
            "0006-r5-c-0000" => 25,
            "0007-r4-c-0000" => 23,
            "0000-c5-a-0001" => 33,
            "0001-m5-a-0001" => 30,
            "0002-r5-a-0001" => 28,
            "0003-r4-a-0001" => 26,
            "0004-c5-c-0001" => 29,
            "0005-m5-c-0001" => 27,
            "0006-r5-c-0001" => 25,
            "0007-r4-c-0001" => 23,
            "1000-c5-a-0000" => 33,
            "1001-r4-a-0000" => 26,
          }
        end

        it "assigns partitions to members considering their instance types and availability zones" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)
          expect(member_id_to_partitions.transform_values(&:size)).to eq(expected_partition_count)
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end

      context "with only one partition" do
        let(:partition_ids) do
          [0]
        end

        let(:member_id_to_userdata) do
          {
            "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
            "0001-m5-a-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
          }
        end

        it "assigns the partition to the member with the highest capacity" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)

          expect(member_id_to_partitions["0000-c5-a-0000"].size).to eq 1
          expect(member_id_to_partitions["0001-m5-a-0000"]).to eq []
        end
      end

      context "when the sum of (capacity * partition_count_per_capacity).round is less than the partition count" do
        let(:partition_ids) { (0 .. 9).to_a }
        let(:member_id_to_userdata) do
          {
            "0000-r4-a-0000" => "i-00000000000000000,r4.xlarge,ap-northeast-1a",
            "0000-r4-a-0001" => "i-00000000000000001,r4.xlarge,ap-northeast-1a",
            "0000-r4-a-0002" => "i-00000000000000002,r4.xlarge,ap-northeast-1a",
          }
        end

        it "assigns partitions to members without omissions" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)

          expect(member_id_to_partitions.keys).to match_array(member_id_to_userdata.keys)
          expect(member_id_to_partitions.values.map(&:size)).to match_array([4, 3, 3])
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end
    end

    context "with weights" do
      # Time for DB access to process one message
      #   ap-northeast-1a: 20 msec
      #   ap-northeast-1c: 30 msec
      # Time except for DB access to process one message
      #   r4: 30 msec
      #   r5: 22 msec
      #   m5: 18 msec
      #   c5: 15 msec

      let(:partition_ids) { (0 .. 500).to_a }
      let(:member_id_to_userdata) do
        {
          # Instances which have two members
          "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0001-m5-a-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
          "0002-r5-a-0000" => "i-00000000000000002,r5.xlarge,ap-northeast-1a",
          "0003-r4-a-0000" => "i-00000000000000003,r4.xlarge,ap-northeast-1a",
          "0004-c5-c-0000" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
          "0005-m5-c-0000" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
          "0006-r5-c-0000" => "i-00000000000000006,r5.xlarge,ap-northeast-1c",
          "0007-r4-c-0000" => "i-00000000000000007,r4.xlarge,ap-northeast-1c",
          "0000-c5-a-0001" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0001-m5-a-0001" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
          "0002-r5-a-0001" => "i-00000000000000002,r5.xlarge,ap-northeast-1a",
          "0003-r4-a-0001" => "i-00000000000000003,r4.xlarge,ap-northeast-1a",
          "0004-c5-c-0001" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
          "0005-m5-c-0001" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
          "0006-r5-c-0001" => "i-00000000000000006,r5.xlarge,ap-northeast-1c",
          "0007-r4-c-0001" => "i-00000000000000007,r4.xlarge,ap-northeast-1c",
          # Instances which have only one member
          "1000-c5-a-0000" => "i-00000000000001000,c5.xlarge,ap-northeast-1a",
          "1001-r4-a-0000" => "i-00000000000001001,r4.xlarge,ap-northeast-1a",
        }
      end

      let(:expected_partition_count) do
        {
          "0000-c5-a-0000" => 36,
          "0001-m5-a-0000" => 33,
          "0002-r5-a-0000" => 28,
          "0003-r4-a-0000" => 25,
          "0004-c5-c-0000" => 28,
          "0005-m5-c-0000" => 26,
          "0006-r5-c-0000" => 23,
          "0007-r4-c-0000" => 21,
          "0000-c5-a-0001" => 36,
          "0001-m5-a-0001" => 33,
          "0002-r5-a-0001" => 28,
          "0003-r4-a-0001" => 25,
          "0004-c5-c-0001" => 28,
          "0005-m5-c-0001" => 26,
          "0006-r5-c-0001" => 23,
          "0007-r4-c-0001" => 21,
          "1000-c5-a-0000" => 36,
          "1001-r4-a-0000" => 25,
        }
      end

      context "with availability zone keys" do
        let(:strategy) do
          described_class.new(
            weights: {
              "r4" => {
                "ap-northeast-1a" => 1.000,
                "ap-northeast-1c" => 0.833,
              },
              "r5" => {
                "ap-northeast-1a" => 1.136,
                "ap-northeast-1c" => 0.926,
              },
              "m5" => {
                "ap-northeast-1a" => 1.316,
                "ap-northeast-1c" => 1.042,
              },
              "c5" => {
                "ap-northeast-1a" => 1.429,
                "ap-northeast-1c" => 1.111,
              },
            },
          )
        end

        it "assigns partitions to members considering their instance types and availability zones" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)
          expect(member_id_to_partitions.transform_values(&:size)).to eq(expected_partition_count)
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end

      context "with availability zone keys" do
        let(:strategy) do
          described_class.new(
            weights: {
              "ap-northeast-1a" => {
                "r4" => 1.000,
                "r5" => 1.136,
                "m5" => 1.316,
                "c5" => 1.429,
              },
              "ap-northeast-1c" => {
                "r4" => 0.833,
                "r5" => 0.926,
                "m5" => 1.042,
                "c5" => 1.111,
              },
            },
          )
        end

        it "assigns partitions to members considering their instance types and availability zones" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)
          expect(member_id_to_partitions.transform_values(&:size)).to eq(expected_partition_count)
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end
    end

    context "with partition_weights" do
      let(:partition_ids) { (0 .. 99).to_a }
      let(:member_id_to_userdata) do
        {
          "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0001-m5-a-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
          "0002-r5-a-0000" => "i-00000000000000001,r5.xlarge,ap-northeast-1a",
          "0003-c5-c-0000" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
          "0004-m5-c-0000" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
        }
      end

      let(:expected_partition_count) do
        {
          "0000-c5-a-0000" => 16,
          "0001-m5-a-0000" => 21,
          "0002-r5-a-0000" => 21,
          "0003-c5-c-0000" => 21,
          "0004-m5-c-0000" => 21,
        }
      end

      context "with partition_weights hash" do
        let(:strategy) do
          described_class.new(
            partition_weights: {
              "topic" => {
                0 => 2,
                1 => 2,
                2 => 2,
                3 => 2,
                4 => 2,
              }
            }
          )
        end

        it "assigns partitions to members considering partition weights" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)
          expect(member_id_to_partitions.transform_values(&:size)).to eq(expected_partition_count)
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end

      context "with partition_weights proc" do
        let(:strategy) do
          described_class.new(
            partition_weights: ->() {
              {
                "topic" => {
                  0 => 2,
                  1 => 2,
                  2 => 2,
                  3 => 2,
                  4 => 2,
                }
              }
            }
          )
        end

        it "assigns partitions to members considering partition weights" do
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)
          expect(member_id_to_partitions.transform_values(&:size)).to eq(expected_partition_count)
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end

      context "with too large weight" do
        let(:strategy) do
          described_class.new(
            partition_weights: {
              "topic" => {
                0 => 100,
              }
            }
          )
        end

        it "assigns partitions to members considering partition weights" do
          expect(member_id_to_partitions.keys).to match_array(member_id_to_userdata.keys)
          expect(member_id_to_partitions.values.map(&:size)).to match_array([1, 25, 25, 25, 24])
          expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
        end
      end
    end

    context "with the same weights" do
      let(:strategy) do
        described_class.new(
          instance_family_weights: {
            "m5" => 1,
            "c5" => 1,
          },
          availability_zone_weights: ->() {
            {
              "ap-northeast-1a" => 1,
              "ap-northeast-1c" => 1,
            }
          },
        )
      end

      let(:partition_ids) { (0 .. 14).to_a }
      let(:member_id_to_userdata) do
        {
          # Instance which has five members
          "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0000-c5-a-0001" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0000-c5-a-0002" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0000-c5-a-0003" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0000-c5-a-0004" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          # Instances which have one member
          "0001-m5-c-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1c",
          "0002-m5-c-0000" => "i-00000000000000002,m5.xlarge,ap-northeast-1c",
          "0003-m5-c-0000" => "i-00000000000000003,m5.xlarge,ap-northeast-1c",
          "0004-m5-c-0000" => "i-00000000000000004,m5.xlarge,ap-northeast-1c",
          "0005-m5-c-0000" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
        }
      end

      let(:expected_partition_count) do
        {
          "0000-c5-a-0000" => 2,
          "0000-c5-a-0001" => 2,
          "0000-c5-a-0002" => 2,
          "0000-c5-a-0003" => 1,
          "0000-c5-a-0004" => 1,
          "0001-m5-c-0000" => 2,
          "0002-m5-c-0000" => 2,
          "0003-m5-c-0000" => 1,
          "0004-m5-c-0000" => 1,
          "0005-m5-c-0000" => 1,
        }
      end

      it "assigns partitions considering instance capacity" do
        expect(member_id_to_partitions.flat_map { |_, a| a.map(&:partition_id) }).to match_array(partition_ids)
        expect(member_id_to_partitions.transform_values(&:size)).to eq(expected_partition_count)
        expect(member_id_to_partitions.flat_map { |_, a| a.map(&:topic) }).to match_array(["topic"] * partition_ids.size)
      end
    end
  end
end
