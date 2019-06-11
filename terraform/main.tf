provider "aws" {
  region = "us-west-2"
  shared_credentials_file = "/Users/uenyioha/.aws/credentials"
}

module "vpc" {
  source = "./modules/terraform-aws-vpc"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = false
  one_nat_gateway_per_az = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

data "http" "myip" {
  url = "http://ipv4.icanhazip.com"
}


module "s3-proxy-dev" {
  source = "./modules/terraform-aws-s3-squid-proxy-farm"
  vpc_id = module.vpc.vpc_id

  subnet_ids = module.vpc.private_subnets

  environment        = "dev"
  proxy_allowed_cidr = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "${module.bastion.private_ip}/32"]
  ssh_allowed_cidr   = "${module.bastion.private_ip}/32"

  extra_tags = {
    "CostCenter" = "Stuff"
    "More"      = "tags"
  }

  ami_id = "ami-01ed306a12b7d1c96" //  CentOS Linux 7 x86_64 HVM EBS ENA 1901_01-b7ee8a69-ee97-4a49-9e68-afaee216db2e-ami-05713873c6794f575.4
}

data "template_file" "script" {
  template = "${file("${path.module}/templates/apply_script.tpl.sh")}"
}

data "template_file" "proxy" {
  template = "${file("${path.module}/templates/proxy.tpl.yaml")}"
  vars = {
    PROXY_URL = "${module.s3-proxy-dev.nlb_dns}"
    VPC_CIDR_RANGE = "${join(",", var.private_subnets)}"
  }
}

data "template_file" "userdata" {
  template = "${file("${path.module}/templates/userdata.tpl.yaml")}"
  vars = {
    PROXY_URL = "${module.s3-proxy-dev.nlb_dns}"
    VPC_CIDR_RANGE = "${join(",", var.private_subnets)}"
  }
}

resource "local_file" "script" {
  content     = "${data.template_file.script.rendered}"
  filename = "${path.module}/output/apply_script.sh"
}

resource "local_file" "proxy" {
  content     = "${data.template_file.proxy.rendered}"
  filename = "${path.module}/output/proxy.yaml"
}

resource "local_file" "userdata" {
  content     = "${data.template_file.userdata.rendered}"
  filename = "${path.module}/output/userdata.tpl.yaml"
}

resource "local_file" "foo" {
  filename = "${path.module}/squid.pem"
  sensitive_content = module.s3-proxy-dev.private_key
}

resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "bastion" {
  key_name   = "bastion-key"
  public_key = tls_private_key.bastion.public_key_openssh
}

resource "local_file" "bastion" {
  filename = "${path.module}/bastion.pem"
  sensitive_content = tls_private_key.bastion.private_key_pem
}

module "bastion" {
  source            = "./modules/terraform-aws-bastion-host"
  subnet_id         = module.vpc.public_subnets[0]
  ssh_key           = aws_key_pair.bastion.key_name
  allowed_hosts     = ["${chomp(data.http.myip.body)}/32"]
  internal_networks = module.vpc.private_subnets_cidr_blocks
  project = "bastion"
}

resource "aws_security_group" "allow_bastion" {
  name        = "allow ssh"
  description = "Allow ssh inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    # TLS (change to whatever ports you need)
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    # Please restrict your ingress to only necessary IPs and ports.
    # Opening to 0.0.0.0/0 can lead to security vulnerabilities.
    cidr_blocks = ["${module.bastion.private_ip}/32"]
  }
}

module "k8s-cluster" {
  source       = "./modules/terraform-aws-eks"
  cluster_name = "my-cluster"
  subnets      = module.vpc.private_subnets
  vpc_id       = module.vpc.vpc_id

  user_data_path = local_file.userdata.filename

  cluster_endpoint_private_access = true

  worker_additional_security_group_ids = [aws_security_group.allow_bastion.id]

  worker_groups = [
    {
      instance_type = "m4.large"
      asg_max_size  = 5
    }
  ]

  workers_group_defaults = {
    key_name = aws_key_pair.bastion.key_name
  }

  tags = {
    environment = "test"
  }
}

output "kubectl" {
  value = module.k8s-cluster.kubeconfig
}

output "ssh_command" {
  value = "ssh -i bastion.pem  ec2-user@[NSTANCE IP] -o \"proxycommand ssh -W %h:%p -i bastion.pem centos@${module.bastion.public_ip}\""
}

//resource "null_resource" "config_kube" {}