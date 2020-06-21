#!/bin/bash

set -eo pipefail

REPOSITORY=ruby-kafka-ec2/benchmark

cd $(dirname $(cd $(dirname $0) && pwd))
repo_uri=$((aws ecr describe-repositories --repository-names $REPOSITORY | jq -r '.repositories[] | .repositoryUri') || true)
if [ -z "$repo_uri" ]; then
  echo "Create ECR repository '$REPOSITORY'"
  repo_uri=$(aws ecr create-repository --repository-name $REPOSITORY | jq -r '.repository.repositoryUri')
fi

echo "Build docker image"
DOCKER_BUILDKIT=1 docker build -t $REPOSITORY . -f benchmark/Dockerfile

echo "Push $repo_uri:latest"
aws ecr get-login-password | docker login --username AWS --password-stdin $repo_uri
docker tag $REPOSITORY:latest $repo_uri:latest
docker push $repo_uri:latest
