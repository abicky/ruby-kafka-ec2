# frozen_string_literal: true

require "kafka"
require "kafka/protocol/member_assignment"

module Kafka
  class EC2
    class MixedInstanceAssignmentStrategy
      DELIMITER = ","

      # @param instance_family_weights [Hash{String => Numeric}, Proc] a hash whose the key
      #   is the instance family and whose value is the weight. If the object is a proc,
      #   it must returns such a hash and the proc is called every time the method "assign"
      #   is called.
      # @param availability_zone_weights [Hash{String => Numeric}, Proc] a hash whose the key
      #   is the availability zone and whose value is the weight. If the object is a proc,
      #   it must returns such a hash and the proc is called every time the method "assign"
      #   is called.
      # @param weights [Hash{String => Hash{String => Numeric}}, Proc] a hash whose the key
      #   is the availability zone or the instance family and whose value is the hash like
      #   instance_family_weights or availability_zone_weights. If the object is a proc,
      #   it must returns such a hash and the proc is called every time the method "assign"
      #   is called.
      def initialize(instance_family_weights: {}, availability_zone_weights: {}, weights: {}, partition_weights: {})
        @instance_family_weights = instance_family_weights
        @availability_zone_weights = availability_zone_weights
        @weights = weights
        @partition_weights = partition_weights
      end

      def protocol_name
        "mixedinstance"
      end

      def user_data
        Net::HTTP.start("169.254.169.254", 80) do |http|
          [
            http.get("/latest/meta-data/instance-id").body,
            http.get("/latest/meta-data/instance-type").body,
            http.get("/latest/meta-data/placement/availability-zone").body,
          ].join(DELIMITER)
        end
      end

      # Assign the topic partitions to the group members.
      #
      # @param members [Array<String>] member ids
      # @param topics [Array<String>] topics
      # @return [Hash{String => Protocol::MemberAssignment}] a hash mapping member
      #   ids to assignments.
      def call(cluster:, members:, partitions:)
        member_id_to_partitions = Hash.new { |h, k| h[k] = [] }
        instance_id_to_capacity = Hash.new(0)
        instance_id_to_member_ids = Hash.new { |h, k| h[k] = [] }
        total_capacity = 0
        member_id_to_instance_id = {}

        instance_family_to_capacity = @instance_family_weights.is_a?(Proc) ? @instance_family_weights.call() : @instance_family_weights
        az_to_capacity = @availability_zone_weights.is_a?(Proc) ? @availability_zone_weights.call() : @availability_zone_weights
        weights = @weights.is_a?(Proc) ? @weights.call() : @weights
        members.each do |member_id, metadata|
          instance_id, instance_type, az = metadata.user_data.split(DELIMITER)
          instance_id_to_member_ids[instance_id] << member_id
          member_id_to_instance_id[member_id] = instance_id
          capacity = calculate_capacity(instance_type, az, instance_family_to_capacity, az_to_capacity, weights)
          instance_id_to_capacity[instance_id] += capacity
          total_capacity += capacity
        end

        partition_weights = build_partition_weights(partitions)
        partition_weight_per_capacity = partitions.sum { |partition| partition_weights.dig(partition.topic, partition.partition_id) } / total_capacity

        last_index = 0
        member_id_to_acceptable_partition_weight = {}
        instance_id_to_total_acceptable_partition_weight = Hash.new(0)
        instance_id_to_capacity.each do |instance_id, capacity|
          member_ids = instance_id_to_member_ids[instance_id]
          member_ids.each do |member_id|
            acceptable_partition_weight = capacity * partition_weight_per_capacity / member_ids.size
            while last_index < partitions.size
              partition = partitions[last_index]
              partition_weight = partition_weights.dig(partition.topic, partition.partition_id)
              break if acceptable_partition_weight - partition_weight < 0

              member_id_to_partitions[member_id] << partition
              acceptable_partition_weight -= partition_weight

              last_index += 1
            end

            member_id_to_acceptable_partition_weight[member_id] = acceptable_partition_weight
            instance_id_to_total_acceptable_partition_weight[instance_id] += acceptable_partition_weight
          end
        end

        while last_index < partitions.size
          max_acceptable_partition_weight = member_id_to_acceptable_partition_weight.values.max
          member_ids = member_id_to_acceptable_partition_weight.select { |_, w| w == max_acceptable_partition_weight }.keys
          if member_ids.size == 1
            member_id = member_ids.first
          else
            member_id =  member_ids.max_by { |id| instance_id_to_total_acceptable_partition_weight[member_id_to_instance_id[id]] }
          end
          partition = partitions[last_index]
          member_id_to_partitions[member_id] << partition

          partition_weight = partition_weights.dig(partition.topic, partition.partition_id)
          member_id_to_acceptable_partition_weight[member_id] -= partition_weight
          instance_id_to_total_acceptable_partition_weight[member_id_to_instance_id[member_id]] -= partition_weight

          last_index += 1
        end

        member_id_to_partitions
      rescue Kafka::LeaderNotAvailable
        sleep 1
        retry
      end

      private

      def calculate_capacity(instance_type, az, instance_family_to_capacity, az_to_capacity, weights)
        instance_family, _ = instance_type.split(".")

        capacity = weights.dig(az, instance_family) || weights.dig(instance_family, az)
        (capacity || instance_family_to_capacity.fetch(instance_family, 1) * az_to_capacity.fetch(az, 1)).to_f
      end

      def build_partition_weights(partitions)
        # Duplicate the weights to not destruct @partition_weights or the return value of @partition_weights
        weights = (@partition_weights.is_a?(Proc) ? @partition_weights.call : @partition_weights).dup
        partitions.map(&:topic).uniq.each do |topic|
          weights[topic] = weights[topic].dup || {}
          weights[topic].default = 1
        end

        weights
      end
    end
  end
end
