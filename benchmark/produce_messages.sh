#!/bin/bash

set -eo pipefail

REPOSITORY=ruby-kafka-ec2/benchmark
TASK_FAMILY=ruby-kafka-ec2-benchmark-producer

repo_uri=$((aws ecr describe-repositories --repository-names $REPOSITORY | jq -r '.repositories[] | .repositoryUri') || true)
if [ -z "$repo_uri" ]; then
  echo "The repository '$REPOSITORY' is not found. Execute register_docker_image.sh first, please." >&2
  exit
fi

aws ecs register-task-definition --cli-input-json "$(cat <<JSON
{
  "family": "$TASK_FAMILY",
  "containerDefinitions": [
    {
      "name": "produce_messages",
      "image": "$repo_uri",
      "command": ["produce_messages.rb"],
      "essential": true,
      "environment": [
        {"name": "KAFKA_BROKERS", "value": "$KAFKA_BROKERS"},
        {"name": "KAFKA_TOPIC", "value": "$KAFKA_TOPIC"},
        {"name": "MYSQL_HOST", "value": "$MYSQL_HOST"},
        {"name": "MYSQL_PASSWORD", "value": "$MYSQL_PASSWORD"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/aws/ecs/ruby-kafka-ec2/benchmark",
          "awslogs-region": "ap-northeast-1",
          "awslogs-stream-prefix": "produce-messages"
        }
      }
    }
  ],
  "cpu": "2048",
  "memory": "4096"
}
JSON
)"

aws ecs run-task --cluster $CLUSTER --task-definition $TASK_FAMILY
