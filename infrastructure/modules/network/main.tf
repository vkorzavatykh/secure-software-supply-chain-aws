# One VPC across two Availability Zones with three tiers (architecture §3):
#   public       ALB and the NAT Gateway        route to the Internet Gateway
#   private app  the Dependency-Track instance  outbound only, through the NAT Gateway
#   private data RDS                            no route to the internet at all

locals {
  # Third octet offset of each tier; the AZ index is added to it (10.20.0.0/24, 10.20.1.0/24, ...).
  tier_offsets = {
    public = 0
    app    = 10
    data   = 20
  }

  az_index = { for index, az in var.availability_zones : az => index }
  nat_az   = var.availability_zones[0]
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are needed for the SSM agent's endpoints and the RDS endpoint name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# The default Security Group allows all traffic between its members. Nothing uses it; strip its rules.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-unused"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# --- Subnets ------------------------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = local.az_index

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.tier_offsets.public + each.value)

  # The ALB and the NAT Gateway get their addresses explicitly; nothing here needs a public IP.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${substr(each.key, -1, 1)}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  for_each = local.az_index

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.tier_offsets.app + each.value)

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-app-${substr(each.key, -1, 1)}"
    Tier = "app"
  }
}

resource "aws_subnet" "data" {
  for_each = local.az_index

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.tier_offsets.data + each.value)

  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-data-${substr(each.key, -1, 1)}"
    Tier = "data"
  }
}

# --- Egress: one NAT Gateway (ADR-007) ----------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.nat_az].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }
}

# --- Route tables -------------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-app"
  }
}

resource "aws_route" "app_internet" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

# Only the implicit local route: the data tier can't reach the internet, and the internet can't reach it.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-data"
  }
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}
