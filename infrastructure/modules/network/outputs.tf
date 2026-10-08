output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in Availability Zone order (load balancer)."
  value       = [for az in var.availability_zones : aws_subnet.public[az].id]
}

output "app_subnet_ids" {
  description = "Private app subnet IDs, in Availability Zone order. Available only once their NAT route exists."
  value       = [for az in var.availability_zones : aws_subnet.app[az].id]

  # The instance bootstraps over the NAT Gateway the moment it boots. Consumers of these IDs must wait
  # for the route, not just for the subnet.
  depends_on = [aws_route.app_internet, aws_route_table_association.app]
}

output "data_subnet_ids" {
  description = "Private data subnet IDs, in Availability Zone order (RDS subnet group)."
  value       = [for az in var.availability_zones : aws_subnet.data[az].id]
}

output "alb_security_group_id" {
  description = "Security Group of the load balancer."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security Group of the Dependency-Track instance."
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "Security Group of the database."
  value       = aws_security_group.db.id
}
