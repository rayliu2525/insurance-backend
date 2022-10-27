#######################################
# Variables
#######################################

variable "provider_region1"                            {}
variable "provider_region2"                            {}
variable "name"                                        {}
variable "owner"                                       {}
variable "environment"                                 {}
variable "vpc_cidr"                                    {}
variable "create_subnet_group"                         {}
variable "create_subnet_group_rt"                      {}
variable "sg_protocol"                                 {}

# DB variables

variable "db_engine"                                   {}
variable "db_engine_version"                           {}
variable "db_family"                                   {}
variable "db_major_engine_version"                     {}
variable "instance_class"                              {}
variable "allocated_storage"                           {}
variable "max_allocated_storage"                       {}
variable "db_name"                                     {}
variable "username"                                    {}
variable "db_port"                                     {}
variable "multi_az"                                    {}
variable "maintenance_window"                          {}
variable "backup_window"                               {}
variable "enabled_cloudwatch_logs_exports"             {}
variable "create_cloudwatch_log_group"                 {}
variable "backup_retention_period"                     {}
variable "skip_final_snapshot"                         {}
variable "deletion_protection"                         {}
variable "aliases_use_name_prefix"                     {}


terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "4.36.1"
    }
  }
}

provider "aws" {
  region = var.provider_region1
}

data "aws_caller_identity" "current" {}

locals {
  name             = var.name
  region           = var.provider_region1
  region2          = var.provider_region2
  current_identity = data.aws_caller_identity.current.arn
  tags = {
    Owner       = var.owner
    Environment = var.environment
  }
}

#######################################
# VPC
#######################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = var.vpc_cidr

  azs              = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnets   = ["10.0.0.0/24", "10.0.0.1/24", "10.0.0.2/24"]
  private_subnets  = ["10.0.0.3/24", "10.0.0.4/24", "10.0.0.5/24"]
  database_subnets = ["10.0.0.6/24", "10.0.0.7/24", "10.0.0.8/24"]

  create_database_subnet_group       = var.create_subnet_group
  create_database_subnet_route_table = var.create_subnet_group_rt

  tags = local.tags
}

#######################################
# DB security group
#######################################

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "Complete PostgreSQL example security group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = var.sg_protocol
      description = "PostgreSQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  tags = local.tags
}

#######################################
# RDS Postgres
#######################################

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = local.name

  engine               = var.db_engine
  engine_version       = var.db_engine_version
  family               = var.db_family
  major_engine_version = var.db_major_engine_version
  instance_class       = var.instance_classs

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  db_name  = var.db_name
  username = var.username
  port     = var.db_port

  multi_az               = var.multi_az
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.security_group.security_group_id]

  maintenance_window              = var.maintenance_window
  backup_window                   = var.backup_window
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  create_cloudwatch_log_group     = var.create_cloudwatch_log_group

  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = var.skip_final_snapshot
  deletion_protection     = var.deletion_protection

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  create_monitoring_role                = true
  monitoring_interval                   = 60
  monitoring_role_name                  = "example-monitoring-role-name"
  monitoring_role_use_name_prefix       = true
  monitoring_role_description           = "Description for monitoring role"

  parameters = [
    {
      name  = "autovacuum"
      value = 1
    },
    {
      name  = "client_encoding"
      value = "utf8"
    }
  ]

  tags = local.tags
  db_option_group_tags = {
    "Sensitive" = "low"
  }
  db_parameter_group_tags = {
    "Sensitive" = "low"
  }
}

#######################################
# RDS Automated Backups
#######################################

provider "aws" {
  alias  = "region2"
  region = local.region2
}

module "kms" {
  source      = "terraform-aws-modules/rds/aws"
  version     = "~> 1.0"
  description = "KMS key for cross region automated backups replication"

  aliases                 = [local.name]
  aliases_use_name_prefix = var.aliases_use_name_prefix

  key_owners = [local.current_identity]

  tags = local.tags

  providers = {
    aws = aws.region2
  }
}

module "db_automated_backups_replication" {
  source = "terraform-aws-modules/rds/aws/modules//db_instance_automated_backups_replication"

  source_db_instance_arn = module.db.db_instance_arn
  kms_key_arn            = module.kms.key_arn

  providers = {
    aws = aws.region2
  }
}