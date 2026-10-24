config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Offline workstations: build the plugin with
#   go install github.com/terraform-linters/tflint-ruleset-aws@v0.50.0
# and copy it to ~/.tflint.d/plugins/github.com/terraform-linters/tflint-ruleset-aws/0.50.0/
plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
