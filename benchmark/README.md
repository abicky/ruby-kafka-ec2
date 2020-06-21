# Benchmark

## Procedures

### 1. Create AWS resources

```
terraform init
terraform apply
```

### 2. Register docker image

```
./register_docker_image.sh
```

### 3. Produce messages and create database records

Set the environment variables `KAFKA_BROKERS`, `KAFKA_TOPIC`, `MYSQL_HOST`, `MYSQL_PASSWORD`, and `CLUSTER`, and execute the following command:

```
./produce_messages.sh
```

### 4. Consume messages

Set the environment variables `KAFKA_BROKERS`, `KAFKA_TOPIC`, `MYSQL_HOST`, `MYSQL_PASSWORD`, and `CLUSTER`, and execute the following command:

```
USE_KAFKA_EC2=false ./consume_messages.sh
```

Stop all the tasks if all lags become 0. You can check the lags by executing the following command in the kafka client instance:

```
./kafka-consumer-groups.sh \
  --bootstrap-server <bootstrap-server> \
  --describe \
  --group net.abicky.ruby-kafka-ec2.benchmark
```

Reset the offsets in the kafka client instance:

```
./kafka-consumer-groups.sh \
  --bootstrap-server <bootstrap-server> \
  --group net.abicky.ruby-kafka-ec2.benchmark \
  --reset-offsets \
  --to-earliest \
  --topic <topic> \
  --execute
```

Set the environment variables `KAFKA_BROKERS`, `KAFKA_TOPIC`, `MYSQL_HOST`, `MYSQL_PASSWORD`, and `CLUSTER`, and execute the following command:

```
USE_KAFKA_EC2=true ./consume_messages.sh
```

## Result

### USE_KAFKA_EC2=false

No. | instance type | availability zone | partition count | processed count | duration (sec)
----|---------------|-------------------|-----------------|-----------------|-----------
1 | m5.large | ap-northeast-1a | 16 | 80000 | 224.1
2 | m5.large | ap-northeast-1a | 17 | 85000 | 237.7
3 | m5.large | ap-northeast-1c | 17 | 85000 | 56.8
4 | m5.large | ap-northeast-1c | 17 | 85000 | 57.3
5 | r4.large | ap-northeast-1a | 16 | 80000 | 257.6
6 | r4.large | ap-northeast-1a | 17 | 85000 | 258.9
7 | r4.large | ap-northeast-1c | 16 | 80000 | 74.2
8 | r4.large | ap-northeast-1c | 17 | 85000 | 76.6
9 | r5.large | ap-northeast-1a | 17 | 80000 | 238.0
10 | r5.large | ap-northeast-1a | 17 | 85000 | 238.1
11 | r5.large | ap-northeast-1c | 16 | 80000 | 54.1
12 | r5.large | ap-northeast-1c | 16 | 85000 | 55.1

See ruby-kafka.log for more details.

### USE_KAFKA_EC2=true

No. | instance type | availability zone | partition count | processed count | duration (sec)
----|---------------|-------------------|-----------------|-----------------|-----------
1 | m5.large | ap-northeast-1a | 7 | 35000 | 101.4
2 | m5.large | ap-northeast-1a | 8 | 40000 | 114.4
3 | m5.large | ap-northeast-1c | 31 | 155000 | 101.6
4 | m5.large | ap-northeast-1c | 30 | 150000 | 98.6
5 | r4.large | ap-northeast-1a | 5 | 25000 | 79.0
6 | r4.large | ap-northeast-1a | 6 | 30000 | 92.4
7 | r4.large | ap-northeast-1c | 23 | 115000 | 105.9
8 | r4.large | ap-northeast-1c | 22 | 110000 | 106.1
9 | r5.large | ap-northeast-1a | 7 | 35000 | 102.1
10 | r5.large | ap-northeast-1a | 7 | 35000 | 102.1
11 | r5.large | ap-northeast-1c | 27 | 135000 | 94.2
12 | r5.large | ap-northeast-1c | 27 | 135000 | 95.7

See ruby-kafka-ec2.log for more details.
