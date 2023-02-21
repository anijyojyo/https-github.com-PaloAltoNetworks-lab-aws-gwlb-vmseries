### Get autogenerated QwikLabs key

data "aws_key_pair" "vmseries" {
  include_public_key = true

  filter {
    name   = "key-name"
    values = [var.vmseries_ssh_key_name]
  }
}


### Locals to build bootstrap options

locals {
  bootstrap_options = {
      mgmt-interface-swap = "enable"
      plugin-op-commands  = "aws-gwlb-inspect:enable, panorama-licensing-mode-on"
      type                = "dhcp-client"
      cgname              = "PANORAMA-LOG-COLLECTOR"
      tplname             = "stack-aws-gwlb-lab"
      dgname              = "AWS-GWLB-LAB"
      auth-key            = var.auth-key
      panorama-server     = var.panorama_host
  }
}


### Module calls for Security VPC and base infrastructure

module "security_vpc" {
  source           = "../modules/vpc"
  global_tags      = var.global_tags
  region           = var.region
  prefix_name_tag  = var.prefix_name_tag
  vpc              = var.security_vpc
  vpc_route_tables = var.security_vpc_route_tables
  subnets          = var.security_vpc_subnets
  nat_gateways     = var.security_nat_gateways
  vpc_endpoints    = var.security_vpc_endpoints
  security_groups  = var.security_vpc_security_groups
}


module "vmseries" {
  source              = "../modules/vmseries"
  region              = var.region
  prefix_name_tag     = var.prefix_name_tag
  ssh_key_name        = data.aws_key_pair.vmseries.key_name
  fw_license_type     = var.fw_license_type
  fw_version          = var.fw_version
  fw_instance_type    = var.fw_instance_type
  tags                = var.global_tags
  interfaces          = var.interfaces
  subnets_map         = module.security_vpc.subnet_ids
  security_groups_map = module.security_vpc.security_group_ids
  firewalls = [
  {
    name    = "vmseries01"
    name_tag = "vmseries01"
    fw_tags = {}
    bootstrap_options = merge(local.bootstrap_options, { "hostname" = "vmseries01"})
    interfaces = [
      { name = "vmseries01-data", index = "0" },
      { name = "vmseries01-mgmt", index = "1" },
    ]
  },
  {
    name        = "vmseries02"
    name_tag    = "vmseries02"
    fw_tags = {}
    bootstrap_options = merge(local.bootstrap_options, { "hostname" = "vmseries02"})
    interfaces = [
      { name = "vmseries02-data", index = "0" },
      { name = "vmseries02-mgmt", index = "1" },
    ]
  }
]
}

module "vpc_routes" {
  source            = "../modules/vpc_routes"
  region            = var.region
  global_tags       = var.global_tags
  prefix_name_tag   = var.prefix_name_tag
  vpc_routes        = var.vpc_routes
  vpc_route_tables  = module.security_vpc.route_table_ids
  internet_gateways = module.security_vpc.internet_gateway_id
  nat_gateways      = module.security_vpc.nat_gateway_ids
  vpc_endpoints     = module.gwlb.endpoint_ids
  transit_gateways  = module.transit_gateways.transit_gateway_ids
}

module "vpc_routes_additional" {
  source            = "../modules/vpc_routes"
  region            = var.region
  global_tags       = var.global_tags
  prefix_name_tag   = var.prefix_name_tag
  vpc_routes        = var.vpc_routes_additional
  vpc_route_tables  = module.security_vpc.route_table_ids
  internet_gateways = module.security_vpc.internet_gateway_id
  nat_gateways      = module.security_vpc.nat_gateway_ids
  vpc_endpoints     = module.gwlb.endpoint_ids
  transit_gateways  = module.transit_gateways.transit_gateway_ids
}


# We need to generate a list of subnet IDs
locals {
  trusted_subnet_ids = [
    for s in var.gateway_load_balancer_subnets :
    module.security_vpc.subnet_ids[s]
  ]
}

module "gwlb" {
  source                          = "../modules/gwlb"
  region                          = var.region
  global_tags                     = var.global_tags
  prefix_name_tag                 = var.prefix_name_tag
  vpc_id                          = module.security_vpc.vpc_id.vpc_id
  gateway_load_balancers          = var.gateway_load_balancers
  gateway_load_balancer_endpoints = var.gateway_load_balancer_endpoints
  name                            = "zzz"
  firewalls                       = module.vmseries.firewalls
  subnet_ids                      = local.trusted_subnet_ids
  subnets_map                     = module.security_vpc.subnet_ids
}

module "transit_gateways" {
  source                          = "../modules/transit_gateway"
  global_tags                     = var.global_tags
  prefix_name_tag                 = var.prefix_name_tag
  subnets                         = module.security_vpc.subnet_ids
  vpcs                            = module.security_vpc.vpc_id
  transit_gateways                = var.transit_gateways
  transit_gateway_vpc_attachments = var.transit_gateway_vpc_attachments
  transit_gateway_peerings        = var.transit_gateway_peerings
}

### AMI and startup script for web servers in spokes

data "aws_ami" "amazon-linux-2" {
  most_recent = true

  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}

locals {
  web_user_data = <<EOF
#!/bin/bash
sleep 120;
until sudo yum update -y; do echo "Retrying"; sleep 5; done
until sudo yum install -y php; do echo "Retrying"; sleep 5; done
until sudo yum install -y httpd; do echo "Retrying"; sleep 5; done
until sudo rm -f /var/www/html/index.html; do echo "Retrying"; sleep 5; done
until sudo wget -O /var/www/html/index.php https://raw.githubusercontent.com/wwce/terraform/master/gcp/adv_peering_2fw_2spoke_common/scripts/showheaders.php; do echo "Retrying"; sleep 2; done
until sudo systemctl start httpd; do echo "Retrying"; sleep 5; done
until sudo systemctl enable httpd; do echo "Retrying"; sleep 5; done
EOF
}

### SSM external module for managing app servers
module "ssm" {
  source                    = "bridgecrewio/session-manager/aws"
  version                   = "0.4.2"
  #vpc_id                    = module.spoke1_vpc.vpc_id.vpc_id
  bucket_name               = "my-session-logs"
  access_log_bucket_name    = "my-session-access-logs"
  tags                      = {
                                Function = "ssm"
                              }
  enable_log_to_s3          = false
  enable_log_to_cloudwatch  = false
  vpc_endpoints_enabled     = false
}


### Module calls for spoke2 VPC

module "spoke1_vpc" {
  source           = "../modules/vpc"
  global_tags      = var.global_tags
  region           = var.region
  prefix_name_tag  = var.prefix_name_tag
  vpc              = var.spoke1_vpc
  vpc_route_tables = var.spoke1_vpc_route_tables
  subnets          = var.spoke1_vpc_subnets
  vpc_endpoints    = var.spoke1_vpc_endpoints
  security_groups  = var.spoke1_vpc_security_groups
}

module "spoke1_vpc_routes" {
  source            = "../modules/vpc_routes"
  region            = var.region
  global_tags       = var.global_tags
  prefix_name_tag   = var.prefix_name_tag
  vpc_routes        = var.spoke1_vpc_routes
  vpc_route_tables  = module.spoke1_vpc.route_table_ids
  internet_gateways = module.spoke1_vpc.internet_gateway_id
  nat_gateways      = module.spoke1_vpc.nat_gateway_ids
  vpc_endpoints     = module.spoke1_gwlb.endpoint_ids
  transit_gateways  = module.spoke1_transit_gateways.transit_gateway_ids
}

module "spoke1_vpc_routes_additional" {
  source            = "../modules/vpc_routes"
  region            = var.region
  global_tags       = var.global_tags
  prefix_name_tag   = var.prefix_name_tag
  vpc_routes        = var.spoke1_vpc_routes_additional
  vpc_route_tables  = module.spoke1_vpc.route_table_ids
  internet_gateways = module.spoke1_vpc.internet_gateway_id
  nat_gateways      = module.spoke1_vpc.nat_gateway_ids
  vpc_endpoints     = module.spoke1_gwlb.endpoint_ids
  transit_gateways  = module.spoke1_transit_gateways.transit_gateway_ids
}

module "spoke1_transit_gateways" {
  source                          = "../modules/transit_gateway"
  global_tags                     = var.global_tags
  prefix_name_tag                 = var.prefix_name_tag
  subnets                         = module.spoke1_vpc.subnet_ids
  vpcs                            = module.spoke1_vpc.vpc_id
  transit_gateways                = var.spoke1_transit_gateways
  transit_gateway_vpc_attachments = var.spoke1_transit_gateway_vpc_attachments
  depends_on = [module.gwlb] // Depends on GWLB being created in security VPC
}

module "spoke1_gwlb" {
  source                          = "../modules/gwlb"
  region                          = var.region
  global_tags                     = var.global_tags
  prefix_name_tag                 = var.prefix_name_tag
  vpc_id                          = module.spoke1_vpc.vpc_id.vpc_id
  gateway_load_balancers          = var.spoke1_gateway_load_balancers
  gateway_load_balancer_endpoints = var.spoke1_gateway_load_balancer_endpoints
  subnets_map                     = module.spoke1_vpc.subnet_ids
  depends_on = [module.transit_gateways] // Depends on GWLB being created in security VPC
}


module "spoke1_ec2_az1" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 4.3"

  name                   = "${var.prefix_name_tag}spoke1-web-az1"
  associate_public_ip_address = false
  iam_instance_profile   = module.ssm.iam_profile_name

  ami                    = data.aws_ami.amazon-linux-2.id
  instance_type          = "t2.micro"
  key_name               = data.aws_key_pair.vmseries.key_name
  monitoring             = true
  vpc_security_group_ids = [module.spoke1_vpc.security_group_ids["web-server-sg"]]
  subnet_id              = module.spoke1_vpc.subnet_ids["web1"]
  user_data_base64 = base64encode(local.web_user_data)
  tags = var.global_tags
}


module "spoke1_ec2_az2" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 4.3"

  name                   = "${var.prefix_name_tag}spoke1-web-az2"
  associate_public_ip_address = false
  iam_instance_profile   = module.ssm.iam_profile_name

  ami                    = data.aws_ami.amazon-linux-2.id
  instance_type          = "t2.micro"
  key_name               = data.aws_key_pair.vmseries.key_name
  monitoring             = true
  vpc_security_group_ids = [module.spoke1_vpc.security_group_ids["web-server-sg"]]
  subnet_id              = module.spoke1_vpc.subnet_ids["web2"]
  user_data_base64 = base64encode(local.web_user_data)
  tags = var.global_tags
}


##################################################################
# Network Load Balancer with Elastic IPs attached
##################################################################
module "spoke1_nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.2"

  name = "${var.prefix_name_tag}spoke1-nlb"

  load_balancer_type = "network"

  vpc_id = module.spoke1_vpc.vpc_id["vpc_id"]

  #   Use `subnets` if you don't want to attach EIPs
  subnets = [module.spoke1_vpc.subnet_ids["alb1"], module.spoke1_vpc.subnet_ids["alb2"]]

  #  TCP_UDP, UDP, TCP
  http_tcp_listeners = [
    {
      port               = 22
      protocol           = "TCP"
      target_group_index = 0
    },
    {
      port               = 80
      protocol           = "TCP"
      target_group_index = 1
    },
  ]

  target_groups = [
    {
      name     = "${var.prefix_name_tag}spoke1-ssh"
      backend_protocol = "TCP"
      backend_port     = 22
      target_type      = "instance"
    },
    {
      name     = "${var.prefix_name_tag}spoke1-http"
      backend_protocol = "TCP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]
}

resource "aws_lb_target_group_attachment" "spoke1_ssh_az1" {
  target_group_arn = module.spoke1_nlb.target_group_arns[0]
  target_id        = module.spoke1_ec2_az1.id
}

resource "aws_lb_target_group_attachment" "spoke1_http_az1" {
  target_group_arn = module.spoke1_nlb.target_group_arns[1]
  target_id        = module.spoke1_ec2_az1.id
}

resource "aws_lb_target_group_attachment" "spoke1_ssh_az2" {
  target_group_arn = module.spoke1_nlb.target_group_arns[0]
  target_id        = module.spoke1_ec2_az2.id
}

resource "aws_lb_target_group_attachment" "spoke1_http_az2" {
  target_group_arn = module.spoke1_nlb.target_group_arns[1]
  target_id        = module.spoke1_ec2_az2.id
}

##################################################################
# Session Manager VPC Endpoints for spoke1 VPC
##################################################################

# SSM, EC2Messages, and SSMMessages endpoints are required for Session Manager
resource "aws_vpc_endpoint" "spoke1_ssm" {
  vpc_id            = module.spoke1_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke1_vpc.subnet_ids["web1"], module.spoke1_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  security_group_ids = [module.spoke1_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke1-ssm-endpoint"})
}

resource "aws_vpc_endpoint" "spoke1_kms" {
  vpc_id            = module.spoke1_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke1_vpc.subnet_ids["web1"], module.spoke1_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.kms"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  security_group_ids = [module.spoke1_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke1-kms-endpoint"})
}

resource "aws_vpc_endpoint" "spoke1_ec2messages" {
  vpc_id            = module.spoke1_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke1_vpc.subnet_ids["web1"], module.spoke1_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  security_group_ids = [module.spoke1_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke1-ec2messages-endpoint"})
}

resource "aws_vpc_endpoint" "spoke1_ssmmessages" {
  vpc_id            = module.spoke1_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke1_vpc.subnet_ids["web1"], module.spoke1_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = trueglobal_tags
  security_group_ids = [module.spoke1_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke1-ssmmessages-endpoint"})
}


### Module calls for spoke2 VPC

module "spoke2_vpc" {
  source           = "../modules/vpc"
  global_tags      = var.global_tags
  region           = var.region
  prefix_name_tag  = var.prefix_name_tag
  vpc              = var.spoke2_vpc
  vpc_route_tables = var.spoke2_vpc_route_tables
  subnets          = var.spoke2_vpc_subnets
  vpc_endpoints    = var.spoke2_vpc_endpoints
  security_groups  = var.spoke2_vpc_security_groups
}


module "spoke2_vpc_routes" {
  source            = "../modules/vpc_routes"
  region            = var.region
  global_tags       = var.global_tags
  prefix_name_tag   = var.prefix_name_tag
  vpc_routes        = var.spoke2_vpc_routes
  vpc_route_tables  = module.spoke2_vpc.route_table_ids
  internet_gateways = module.spoke2_vpc.internet_gateway_id
  nat_gateways      = module.spoke2_vpc.nat_gateway_ids
  vpc_endpoints     = module.spoke2_gwlb.endpoint_ids
  transit_gateways  = module.spoke2_transit_gateways.transit_gateway_ids
}

module "spoke2_vpc_routes_additional" {
  source            = "../modules/vpc_routes"
  region            = var.region
  global_tags       = var.global_tags
  prefix_name_tag   = var.prefix_name_tag
  vpc_routes        = var.spoke2_vpc_routes_additional
  vpc_route_tables  = module.spoke2_vpc.route_table_ids
  internet_gateways = module.spoke2_vpc.internet_gateway_id
  nat_gateways      = module.spoke2_vpc.nat_gateway_ids
  vpc_endpoints     = module.spoke2_gwlb.endpoint_ids
  transit_gateways  = module.spoke2_transit_gateways.transit_gateway_ids
}

module "spoke2_transit_gateways" {
  source                          = "../modules/transit_gateway"
  global_tags                     = var.global_tags
  prefix_name_tag                 = var.prefix_name_tag
  subnets                         = module.spoke2_vpc.subnet_ids
  vpcs                            = module.spoke2_vpc.vpc_id
  transit_gateways                = var.spoke2_transit_gateways
  transit_gateway_vpc_attachments = var.spoke2_transit_gateway_vpc_attachments
  depends_on = [module.gwlb] // Depends on GWLB being created in security VPC
}

module "spoke2_gwlb" {
  source                          = "../modules/gwlb"
  region                          = var.region
  global_tags                     = var.global_tags
  prefix_name_tag                 = var.prefix_name_tag
  vpc_id                          = module.spoke2_vpc.vpc_id.vpc_id
  gateway_load_balancers          = var.spoke2_gateway_load_balancers
  gateway_load_balancer_endpoints = var.spoke2_gateway_load_balancer_endpoints
  subnets_map                     = module.spoke2_vpc.subnet_ids
  depends_on = [module.transit_gateways] // Depends on GWLB being created in security VPC
}


module "spoke2_ec2_az1" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 4.3"

  name                   = "${var.prefix_name_tag}spoke2-web-az1"
  associate_public_ip_address = false
  iam_instance_profile   = module.ssm.iam_profile_name

  ami                    = data.aws_ami.amazon-linux-2.id
  instance_type          = "t2.micro"
  key_name               = data.aws_key_pair.vmseries.key_name
  monitoring             = true
  vpc_security_group_ids = [module.spoke2_vpc.security_group_ids["web-server-sg"]]
  subnet_id              = module.spoke2_vpc.subnet_ids["web1"]
  user_data_base64 = base64encode(local.web_user_data)
  tags = var.global_tags
}


module "spoke2_ec2_az2" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  version                = "~> 4.3"

  name                   = "${var.prefix_name_tag}spoke2-web-az2"
  associate_public_ip_address = false
  iam_instance_profile   = module.ssm.iam_profile_name

  ami                    = data.aws_ami.amazon-linux-2.id
  instance_type          = "t2.micro"
  key_name               = data.aws_key_pair.vmseries.key_name
  monitoring             = true
  vpc_security_group_ids = [module.spoke2_vpc.security_group_ids["web-server-sg"]]
  subnet_id              = module.spoke2_vpc.subnet_ids["web2"]
  user_data_base64 = base64encode(local.web_user_data)
  tags = var.global_tags
}

##################################################################
# Network Load Balancer with Elastic IPs attached
##################################################################
module "spoke2_nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.2"

  name = "${var.prefix_name_tag}spoke2-nlb"

  load_balancer_type = "network"

  vpc_id = module.spoke2_vpc.vpc_id["vpc_id"]

  #   Use `subnets` if you don't want to attach EIPs
  subnets = [module.spoke2_vpc.subnet_ids["alb1"], module.spoke2_vpc.subnet_ids["alb2"]]

  #  TCP_UDP, UDP, TCP
  http_tcp_listeners = [
    {
      port               = 22
      protocol           = "TCP"
      target_group_index = 0
    },
    {
      port               = 80
      protocol           = "TCP"
      target_group_index = 1
    },
  ]

  target_groups = [
    {
      name     = "${var.prefix_name_tag}spoke2-ssh"
      backend_protocol = "TCP"
      backend_port     = 22
      target_type      = "instance"
    },
    {
      name     = "${var.prefix_name_tag}spoke2-http"
      backend_protocol = "TCP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]
}

resource "aws_lb_target_group_attachment" "spoke2_ssh_az1" {
  target_group_arn = module.spoke2_nlb.target_group_arns[0]
  target_id        = module.spoke2_ec2_az1.id
}

resource "aws_lb_target_group_attachment" "spoke2_http_az1" {
  target_group_arn = module.spoke2_nlb.target_group_arns[1]
  target_id        = module.spoke2_ec2_az1.id
}

resource "aws_lb_target_group_attachment" "spoke2_ssh_az2" {
  target_group_arn = module.spoke2_nlb.target_group_arns[0]
  target_id        = module.spoke2_ec2_az2.id
}

resource "aws_lb_target_group_attachment" "spoke2_http_az2" {
  target_group_arn = module.spoke2_nlb.target_group_arns[1]
  target_id        = module.spoke2_ec2_az2.id
}

##################################################################
# Session Manager VPC Endpoints for spoke2 VPC
##################################################################

# SSM, EC2Messages, and SSMMessages endpoints are required for Session Manager
resource "aws_vpc_endpoint" "spoke2_ssm" {
  vpc_id            = module.spoke2_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke2_vpc.subnet_ids["web1"], module.spoke2_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  security_group_ids = [module.spoke2_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke2-ssm-endpoint"})
}

resource "aws_vpc_endpoint" "spoke2_kms" {
  vpc_id            = module.spoke2_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke2_vpc.subnet_ids["web1"], module.spoke2_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.kms"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  security_group_ids = [module.spoke2_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke2-kms-endpoint"})
}

resource "aws_vpc_endpoint" "spoke2_ec2messages" {
  vpc_id            = module.spoke2_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke2_vpc.subnet_ids["web1"], module.spoke2_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.ec2messages"
  private_dns_enabled = true
  vpc_endpoint_type = "Interface"
  security_group_ids = [module.spoke2_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke2-ec2messages-endpoint"})
}

resource "aws_vpc_endpoint" "spoke2_ssmmessages" {
  vpc_id            = module.spoke2_vpc.vpc_id.vpc_id
  subnet_ids        = [module.spoke2_vpc.subnet_ids["web1"], module.spoke2_vpc.subnet_ids["web2"]]
  service_name      = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  security_group_ids = [module.spoke2_vpc.security_group_ids["web-server-sg"]]
  tags                = merge(var.global_tags, { "Name" = "gwlb-lab-spoke2-ssmmessages-endpoint"})
}