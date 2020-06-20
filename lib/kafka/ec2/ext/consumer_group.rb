# frozen_string_literal: true

require "kafka/consumer_group"
require "kafka/ec2/mixed_instance_assignment_strategy"

module Kafka
  class EC2
    module Ext
      module ConsumerGroup
        def initialize(*args, **kwargs)
          super
          if Kafka::EC2.assignment_strategy_factory
            @assignment_strategy = Kafka::EC2.assignment_strategy_factory.create(cluster: @cluster)
          end
          Kafka::EC2.assignment_strategy_classes[@group_id] = @assignment_strategy.class
        end

        def join_group
          super
          if Kafka::EC2.assignment_strategy_classes[@group_id] == Kafka::EC2::MixedInstanceAssignmentStrategy
            @assignment_strategy.member_id_to_metadata = @members
          end
        end
      end
    end
  end
end

module Kafka
  class ConsumerGroup
    prepend Kafka::EC2::Ext::ConsumerGroup
  end
end
