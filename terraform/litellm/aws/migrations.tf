# Task definition for `python litellm/proxy/prisma_migration.py` against the
# writer DB using IAM auth. Mirrors the chart's post-install Helm hook.
#
# Invoked automatically by `terraform_data.migration` in bootstrap.tf during
# every apply (after the IAM-authed user has been created). The
# `migration_run_command` output is preserved for break-glass manual re-runs.
resource "aws_ecs_task_definition" "migrations" {
  family                   = "${var.name}-migrations"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  # Prisma migrate + the proxy_server import chain needs >1 GiB. Sized to
  # match gateway so we know it fits everywhere gateway fits.
  cpu                = 1024
  memory             = 4096
  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge(
      {
        name      = "migrations"
        image     = var.backend_image
        essential = true

        environment = concat(
          local.shared_env,
          local.proxy_config_env,
          [{ name = "DISABLE_SCHEMA_UPDATE", value = "false" }],
        )
        secrets = local.shared_secrets

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.migrations.name
            awslogs-region        = var.region
            awslogs-stream-prefix = "migrations"
          }
        }
      },
      # Override entrypoint to run prisma_migration.py instead of the
      # image's default uvicorn invocation. When proxy_config is provided,
      # also write the decoded YAML to /tmp before the migration runs (the
      # migration script imports proxy_server which reads CONFIG_FILE_PATH).
      local.proxy_config_enabled ? {
        entryPoint = ["sh", "-c"]
        command = [
          "python -c \"import os, base64, pathlib; pathlib.Path(os.environ['CONFIG_FILE_PATH']).write_bytes(base64.b64decode(os.environ['LITELLM_PROXY_CONFIG_B64']))\" && exec python litellm/proxy/prisma_migration.py"
        ]
        } : {
        entryPoint = ["python"]
        command    = ["litellm/proxy/prisma_migration.py"]
      },
    )
  ])
}
