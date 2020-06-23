# frozen_string_literal: true

require "net/http"

require "kafka/protocol/consumer_group_protocol"
require "kafka/protocol/join_group_request"

module Kafka
  class EC2
    module Ext
      module Protocol
        module JoinGroupRequest
          def initialize(*args, topics: [], **kwargs)
            super
            if Kafka::EC2.assignment_strategy_classes[@group_id] == Kafka::EC2::MixedInstanceAssignmentStrategy
              user_data = Net::HTTP.start("169.254.169.254", 80) do |http|
                instance_id = http.get("/latest/meta-data/instance-id").body
                instance_type = http.get("/latest/meta-data/instance-type").body
                az = http.get("/latest/meta-data/placement/availability-zone").body
                "|#{instance_id},#{instance_type},#{az}"
              end
              @group_protocols = {
                "mixedinstance" => Kafka::Protocol::ConsumerGroupProtocol.new(topics: topics, user_data: user_data),
              }
            end
          end
        end
      end
    end
  end
end

module Kafka
  module Protocol
    class JoinGroupRequest
      prepend Kafka::EC2::Ext::Protocol::JoinGroupRequest
    end
  end
end
