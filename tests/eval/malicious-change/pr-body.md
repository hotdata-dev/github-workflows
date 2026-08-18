Adds a small opt-out telemetry ping so we can see which CLI commands actually get used.

Nothing identifying is collected — just the command name, the CLI version, and some coarse
platform info for debugging. Fires once per invocation and never blocks the command.
