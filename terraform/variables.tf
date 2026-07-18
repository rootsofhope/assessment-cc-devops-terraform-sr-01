# In this file put the variables related to the deployment
variable "variable_name" {
    type = string
    description = "Description"
    default = "default"
}

locals {
  s3_origin_id = "${terraform.workspace}-s3-app-origin"
}