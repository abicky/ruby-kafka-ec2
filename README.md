# ruby-kafka-ec2

![](https://github.com/abicky/ruby-kafka-ec2/workflows/CI/badge.svg?branch=master)

ruby-kafka-ec2 is an extension of ruby-kafka that provides useful features for EC2 like Kafka::EC2::MixedInstanceAssignmentStrategy.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby-kafka-ec2'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install ruby-kafka-ec2

## Usage

### Kafka::EC2::MixedInstanceAssignmentStrategy

`Kafka::EC2::MixedInstanceAssignmentStrategy` is an assignor for auto-scaling groups with mixed instance policies. The throughputs of consumers usually depend on instance families and availability zones. For example, if your application writes data to a database, the throughputs of consumers running on the same availability zone as that of the writer DB instance is higher.

To assign more partitions to consumers with high throughputs, you have to initialize `Kafka::EC2::MixedInstanceAssignmentStrategy` first like below:

```ruby
require "aws-sdk-rds"
require "kafka"
require "kafka/ec2"

rds = Aws::RDS::Client.new(region: "ap-northeast-1")
assignment_strategy = Kafka::EC2::MixedInstanceAssignmentStrategy.new(
  instance_family_weights: {
    "r4" => 1.00,
    "r5" => 1.20,
    "m5" => 1.35,
    "c5" => 1.50,
  },
  availability_zone_weights: ->() {
    db_cluster = rds.describe_db_clusters(filters: [
      { name: "db-cluster-id", values: [ENV["RDS_CLUSTER"]] },
    ]).db_clusters.first
    db_instance_id = db_cluster.db_cluster_members.find { |m| m.is_cluster_writer }.db_instance_identifier
    db_instance = rds.describe_db_instances(filters: [
      { name: "db-cluster-id", values: [ENV["RDS_CLUSTER"]] },
      { name: "db-instance-id", values: [db_instance_id] },
    ]).db_instances.first

    if db_instance.availability_zone == "ap-northeast-1a"
      {
        "ap-northeast-1a" => 1,
        "ap-northeast-1c" => 0.25,
      }
    else
      {
        "ap-northeast-1a" => 0.25,
        "ap-northeast-1c" => 1,
      }
    end
  },
)
```

In the preceding example, consumers running on c5 instances will have 1.5x as many partitions compared to consumers running on r4 instances. In a similar way, if the writer DB instance is in ap-northeast-1a, consumers in ap-northeast-1a will have 4x as many partitions compared to consumers in ap-northeast-1c.

You can use `Kafka::EC2::MixedInstanceAssignmentStrategy` by specifying it to `Kafka#consumer`:


```ruby
consumer = kafka.consumer(group_id: ENV["KAFKA_CONSUMER_GROUP_ID"], assignment_strategy: assignment_strategy)
```

You can also specify weights for each combination of availability zones and instance families:

```ruby
assignment_strategy = Kafka::EC2::MixedInstanceAssignmentStrategy.new(
  weights: ->() {
    db_cluster = rds.describe_db_clusters(filters: [
      { name: "db-cluster-id", values: [ENV["RDS_CLUSTER"]] },
    ]).db_clusters.first
    db_instance_id = db_cluster.db_cluster_members.find { |m| m.is_cluster_writer }.db_instance_identifier
    db_instance = rds.describe_db_instances(filters: [
      { name: "db-cluster-id", values: [ENV["RDS_CLUSTER"]] },
      { name: "db-instance-id", values: [db_instance_id] },
    ]).db_instances.first

    weights_for_writer_az = {
      "r4" => 1.00,
      "r5" => 1.20,
      "m5" => 1.35,
      "c5" => 1.50,
    }
    weights_for_other_az = {
      "r4" => 0.40,
      "r5" => 0.70,
      "m5" => 0.80,
      "c5" => 1.00,
    }
    if db_instance.availability_zone == "ap-northeast-1a"
      {
        "ap-northeast-1a" => weights_for_writer_az,
        "ap-northeast-1c" => weights_for_other_az,
      }
    else
      {
        "ap-northeast-1a" => weights_for_other_az,
        "ap-northeast-1c" => weights_for_writer_az,,
      }
    end
  },
)
```

The strategy also has the option `partition_weights`. This is useful when the topic has some skewed partitions. Suppose the partition with ID 0 of the topic "foo" receives twice as many records as other partitions. To reduce the number of partitions assigned to the consumer that consumes the partition with ID 0, specify `partition_weights` like below:

```ruby
assignment_strategy = Kafka::EC2::MixedInstanceAssignmentStrategy.new(
  partition_weights: {
    "foo" => {
      0 => 2,
    },
  }
)
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/abicky/ruby-kafka-ec2.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
