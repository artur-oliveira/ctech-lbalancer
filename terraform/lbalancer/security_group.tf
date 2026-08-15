# Port of load-balancer-stack.ts:72-78 (Ipv6EgressSg).
# The imported edge SG has IPv4-only default egress; this scoped second SG lets
# the public-IPv6/no-public-IPv4 instance reach SSM and package endpoints.

resource "aws_security_group" "ipv6_egress" {
  name        = "${var.environment}-ctech-lbalancer-ipv6-egress-sg${var.resource_suffix}"
  description = "IPv6 internet egress for the CTech HAProxy instance"
  vpc_id      = data.aws_vpc.this.id

  egress {
    description      = "All IPv6 outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    ipv6_cidr_blocks = ["::/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}
