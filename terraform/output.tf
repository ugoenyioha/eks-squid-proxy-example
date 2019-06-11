## Expose the module outputs.
output "private_key" {
  value = module.s3-proxy-dev.private_key
}

output "nlb_dns" {
  value = module.s3-proxy-dev.nlb_dns
}