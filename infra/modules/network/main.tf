# Public subnets only, with no NAT gateway and no load balancer (ADR-0009).
#
# Nodes are given public IPv4 addresses so that they can reach Amazon ECR,
# Bedrock and the Kubernetes API without a NAT gateway. Nothing routes inbound:
# the node security group has no ingress rule, and no load balancer or public
# endpoint is created here.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Each public subnet takes one /24 of the VPC block, so three subnets fit in a
  # /16 and the addressing stays readable in a route table.
  public_subnet_cidrs = [for index in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 8, index)]
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # The cluster resolves its own service names through the VPC resolver, which
  # needs both settings.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]

  # Without a NAT gateway this is how a node reaches the internet: it receives a
  # public address and the route table sends its traffic through the gateway.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-public-${local.availability_zones[count.index]}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
