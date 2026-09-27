R14 cross-phase (R04/R05/R06/R12):
X1 P2 renameProject drops ProjectEntry.extra → archive record lost (ProjectsViewModel.swift:563-569); fix carry extra.
X2 P2 (pre-existing) Server Restore pauses only root cron; profiles/*/cron/jobs.json stay armed (RemoteRestoreService pauseAllCronJobs ~:881; Hermes cron per-profile jobs.py:62-74, gateway ticks all run.py:5672-5685).
X3 P2→treat P1 (pre-existing, security) "Include auth" off still ships profiles/*/auth.json; also mcp-tokens, gateway_state.json root-anchored excludes (RemoteBackupService.swift:529).
X4 P3 ProjectDoctor path-reuse ignores [tmpl:][proj:] (ProjectDoctorService.swift:360-364) — no practical impact; stale docs scarf-template-author/SKILL.md:408,512, scarf-export.md:17.
X5 P3 exporter follows symlinks inside skills → can pull outside files (e.g. .env) into shareable bundle (ProjectTemplateExporter.swift ~375-392).
C3 scope: restore swap covers profile state.db + kanban.db — within Alan's approval (question named "state.db (and other Hermes .db files)").
