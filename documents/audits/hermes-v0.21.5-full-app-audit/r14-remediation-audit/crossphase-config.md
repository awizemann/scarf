R14 cross-phase config/MCP/gateway/transport:
F1 P2 (reproduced) remote Terminal paths fail on csh/tcsh login shell: `env PATH="$PATH:..."` — `$PATH:` is a csh modifier (ChatViewModel.swift:3252-3253, GatewaySetupTerminalCommand.swift:31, HermesConfigReader.pathFallback :37). Use "${PATH}:".
F2 P3 probed hermes path with a space saved unquoted → treated as shell fragment → exit 127 (AddServerViewModel.swift:125-126, HermesPathSet.swift:158-163, ServerContext.hermesBinaryProbablyResolvable :479).
F3 P3 credential hint ignores provider aliases for scoped tokens (HermesProviderCredentials.swift:73-77 vs auth.py:1315-1330).
Nit: MCPLoginController cites SSHTransport.swift:693-716 (now 744-770).
Clean: pins/wrappers/PATH combos, MCP login stdin, OAuth catalog add, managed check, floors, argv, gateway pgrep, WhatsApp save.
