-- Desktop integration choices shared across the shell.
return {
  icon_theme = "Adwaita",
  -- Terminal desktop entries run as `terminal_argv COMMAND ARG...`.
  terminal_argv = { "monstar", "-e" },
  -- PAM policy must be installed/reviewed for the machine; never accept a
  -- service or account name supplied by lock-screen input or an MCP request.
  pam_service = "login",
  idle = { lock_ms = 5 * 60 * 1000, power_ms = 10 * 60 * 1000, suspend_ms = 30 * 60 * 1000 },
}
