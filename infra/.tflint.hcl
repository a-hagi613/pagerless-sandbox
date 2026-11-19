# tflint inspects the AWS resources in this configuration and in the modules it
# calls, so that a rule failure is caught on the pull request rather than in a
# paid session. The plugin version is pinned like every other dependency.
plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "all"
}
