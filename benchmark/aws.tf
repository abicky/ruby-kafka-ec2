provider "aws" {
  region = "ap-northeast-1"
}

variable "vpc_id" {}
variable "ec2_instance_security_group_id" {}
variable "ec2_key_name" {}
variable "rds_master_password" {}
variable "kafka_broker_subnet_ids" {}

# RDS

resource "aws_security_group" "rds" {
  name        = "ruby-kafka-ec2-rds"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "rds_access_from_ec2" {
  security_group_id        = aws_security_group.rds.id
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = var.ec2_instance_security_group_id
}


resource "aws_rds_cluster" "benchmark" {
  cluster_identifier              = "ruby-kafka-ec2-benchmark"
  engine                          = "aurora"
  engine_mode                     = "provisioned"
  engine_version                  = "5.6.10a"
  availability_zones              = ["ap-northeast-1a", "ap-northeast-1c"]
  master_username                 = "admin"
  master_password                 = var.rds_master_password
  backup_retention_period         = 1
  skip_final_snapshot             = true
  vpc_security_group_ids          = [aws_security_group.rds.id]
}

resource "aws_rds_cluster_instance" "instances" {
  count                   = 1
  identifier              = "${aws_rds_cluster.benchmark.cluster_identifier}-${count.index}"
  cluster_identifier      = aws_rds_cluster.benchmark.id
  instance_class          = "db.r5.large"
}

# Kafka

data "aws_kms_key" "kafka" {
  key_id = "alias/aws/kafka"
}

resource "aws_security_group" "kafka_cluster" {
  name   = "ruby-kafka-ec2-kafka-cluster"
  vpc_id = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "kafka_cluster_from_ec2" {
  security_group_id = aws_security_group.kafka_cluster.id
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  source_security_group_id = var.ec2_instance_security_group_id
}

resource "aws_msk_cluster" "benchmark" {
  cluster_name           = "ruby-kafka-ec2-benchmark"
  kafka_version          = "2.2.1"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    ebs_volume_size = "100"
    client_subnets = var.kafka_broker_subnet_ids
    security_groups = [aws_security_group.kafka_cluster.id]
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = data.aws_kms_key.kafka.arn

    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = true
    }
  }
}

data "aws_ami" "most_recent_amazon_linux2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-2.0.*-x86_64-gp2"]
  }
}

resource "aws_instance" "kafka_client" {
  ami           = data.aws_ami.most_recent_amazon_linux2.image_id
  instance_type = "t3.nano"
  key_name      = var.ec2_key_name

  subnet_id              = var.kafka_broker_subnet_ids[0]
  vpc_security_group_ids = [var.ec2_instance_security_group_id]

  associate_public_ip_address = true

  # cf. https://docs.aws.amazon.com/msk/latest/developerguide/create-client-machine.html
  user_data = <<EOF
#!/bin/bash
yum install -y java-1.8.0
wget https://archive.apache.org/dist/kafka/2.2.1/kafka_2.12-2.2.1.tgz
tar -xzf kafka_2.12-2.2.1.tgz
EOF

  tags = {
    Name = "kafka-client"
  }
}
