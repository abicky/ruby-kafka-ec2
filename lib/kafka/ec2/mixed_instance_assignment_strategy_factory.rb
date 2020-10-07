# frozen_string_literal: true

require "kafka/ec2/mixed_instance_assignment_strategy"

module Kafka
  class EC2
    class MixedInstanceAssignmentStrategyFactory
      # @param instance_family_weights [Hash, Proc]
      # @param availability_zone_weights [Hash, Proc]
      # @param weights [Hash, Proc]
      # @see Kafka::EC2::MixedInstanceAssignmentStrategy#initialize
      def initialize(instance_family_weights: {}, availability_zone_weights: {}, weights: {}, partition_weights: {})
        @instance_family_weights = instance_family_weights
        @availability_zone_weights = availability_zone_weights
        @weights = weights
        @partition_weights = partition_weights
      end

      def create(cluster:)
        Kafka::EC2::MixedInstanceAssignmentStrategy.new(
          cluster: cluster,
          instance_family_weights: @instance_family_weights,
          availability_zone_weights: @availability_zone_weights,
          weights: @weights,
          partition_weights: @partition_weights,
        )
      end
    end
  end
end
