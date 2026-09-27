import re,sys,collections
files=[l.strip() for l in open(sys.argv[1]) if l.strip()]
R=[
("S01-chat-transport", r"/ACP/|ACPClient\+|SSHExecACPChannel|ProcessACPChannel|ACPMessages"),
("S02-chat-events", r"RichChatViewModel|Features/Chat/ViewModels|ChatImageAttachment|SessionCostDisplay"),
("S03-chat-surfaces", r"Features/Chat/|VoiceLive|SpeechService|MessageSpeech|HermesTTS|Features/(Personalities|QuickCommands)|HermesPersonalities|QuickCommandsYAML|HermesSlashCommand|SlashCommandBootstrap|BuiltinSlashCommands|ProjectSlashCommand|ChatNotification"),
("S04-sessions-data", r"HermesDataService|Backends/|SessionPreviewSQL|HermesSearchIndex|SessionAttribution|SessionProjectMap|Features/(Sessions|Activity|Insights|Dashboard)|IOSDashboard"),
("S06-models-providers", r"ModelCatalog|ModelPreflight|ModelPreset|NousModel|NousAuth|NousSubscription|LocalModel|Features/(Models|CredentialPools|Proxy)|HermesProxyService|ProjectModelPreset"),
("S07-gateway-platforms", r"Gateway|Features/(Platforms|Webhooks)|HermesWebhookList|HermesPlatformSharedKeys|SpotifyAuthFlow"),
("S08-cron", r"Cron|OAuthKeepalive"),
("S09-mcp", r"MCPServers|HermesMCP(Add|OAuthPaths|DevicePrompt)|Features/MCP"),
("S10-skills-plugins", r"Skill(?!sViewModel.*Project)|Plugin|Curator|Features/Tools|HermesToolsList|HermesApprovalsSuggest"),
("S12-projects-templates", r"Template|CatalogService|ProjectScaffold|ProjectsMCP|ScarfProjectsMCPKit|scarf-projects-mcp|MiniApp|ProjectUpgrade"),
("S11-projects-core", r"Project|Fleet|SidebarProjectsWell|RegistryWriteLock|ProjectRoot"),
("S13-kanban-bots-peers-profiles", r"Kanban|Bot|Peer|Profile"),
("S14-health-logs-memory-backup", r"Features/(Health|Logs|Memory)|IOSMemory|Backup|Restore|Updater|HermesEnvService|KeychainEnvMirror|SecretsEnvBlock|HermesPythonDiscovery|HermesVersionCache|HermesCapabilities|PowerSettingsWriter"),
("S05-config-settings", r"Features/Settings|HermesConfig|HermesYAML|YAMLScalar|YAMLLineEndings|ConfigDottedKey|IOSSettings|HermesApprovalMode|GuardedJSONStore|GuardedTextFile|JSONValue"),
("S15-servers-transport-ios", r"Transport|Features/Servers|ServerContext|ServerRegistry|ConnectionStatus|Security/|Scarf iOS/|ScarfIOS/|HermesPathSet|HermesCLIRunner|HermesCLIOutcome|HermesFileWatcher|AppCoordinator|SidebarView|scarfApp"),
("SHARED", r"HermesFileService|Localizable"),
]
out=collections.defaultdict(list); un=[]
for f in files:
    for n,p in R:
        if re.search(p,f): out[n].append(f); break
    else: un.append(f)
for n in sorted(out): print(n,len(out[n]))
print("UNASSIGNED",len(un)); print("\n".join(un))
import json; json.dump(out,open(sys.argv[2],'w'),indent=1)
