# Graph Report - docker-odoo  (2026-11-05)

## Corpus Check
- 82 files · ~69,443 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 978 nodes · 1689 edges · 71 communities (57 shown, 14 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 10 edges (avg confidence: 0.5)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b2420fe2`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- snapshot_storage.sh
- setup.sh
- Critical Workflows
- restore-snapshot.sh
- ssh_utils.sh
- dataodoo-backupper.sh
- filestore-manager.sh
- scripts/README.md
- git_addons_updater.sh
- git_odoo-base_updater.sh
- .uninstall-odoo.sh
- Maintenance
- install-snapshot.sh
- long-process-mode.sh
- dataodoo-remover.sh
- download-snapshot.sh
- install-databasecloner.sh
- install-deploy_release_candidate.sh
- queue_lock.sh
- utilities/install-font.sh
- cleanup-snapshot.sh
- install-docker_logs_rotator.sh
- list-snapshot.sh
- entrypoint.sh
- change-snapshot-remote.sh
- dataodoo-password_changer.sh
- generate_map.sh
- scripts/install-font.sh
- install-backupdata.sh
- install-restore_backupdata.sh
- install_sudoers.sh
- test_deploy_release_candidate.sh
- setup_nginx_cache_conf.sh
- setup_nginx_security_conf.sh
- add_hostname_to_btop_titlebar.sh
- install-code_server.sh
- uninstall-code_server.sh
- uninstall-snapshot.sh
- rename_project.sh
- switch_env.sh
- transfer_pg_ownership.sh
- update-env-file.sh
- update-odoo-config.sh
- bump_image_version.sh
- install-dump_database.sh
- install-export_filestore.sh
- change_database.sh
- disk_free_monitor.sh
- update-deployment-tool.sh
- get-code-server-env.sh
- list-databases.sh
- validate-agent-config.sh
- Phased Execution
- knowledge/README.md
- how-to-scan-repository.md
- ponytail-ref.md
- conf/README.md
- git/README.md
- create-deployment-dir.sh
- generate-deploy-rc-ssh-key.sh
- git-helper.sh
- check_odoo_health.sh
- filter_odoo_log.sh
- read-config-file.sh
- save-config-file.sh
- bash-script-template.sh
- utilities/README.md

## God Nodes (most connected - your core abstractions)
1. `main()` - 26 edges
2. `log_info()` - 19 edges
3. `log_error()` - 18 edges
4. `restoreSnapshotFull()` - 17 edges
5. `log_error()` - 16 edges
6. `log_success()` - 15 edges
7. `restoreSnapshotDataOnly()` - 14 edges
8. `main()` - 12 edges
9. `log_info()` - 12 edges
10. `main()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `verifySnapshotChecksum()` --calls--> `snap_verify_file()`  [EXTRACTED]
  scripts/restore-snapshot.sh → scripts/lib/snapshot_storage.sh
- `download-snapshot.sh script` --calls--> `gds_download()`  [EXTRACTED]
  scripts/download-snapshot.sh → scripts/lib/snapshot_storage.sh
- `download-snapshot.sh script` --calls--> `snap_write_sidecar()`  [EXTRACTED]
  scripts/download-snapshot.sh → scripts/lib/snapshot_storage.sh
- `generate-snapshot-ssh-key.sh script` --calls--> `install_pubkey_via_admin()`  [EXTRACTED]
  scripts/generate-snapshot-ssh-key.sh → scripts/lib/ssh_utils.sh
- `restoreSnapshotDataOnly()` --calls--> `trigger_registry_reload()`  [EXTRACTED]
  scripts/restore-snapshot.sh → scripts/lib/odoo_utils.sh

## Import Cycles
- None detected.

## Communities (71 total, 14 thin omitted)

### Community 0 - "snapshot_storage.sh"
Cohesion: 0.06
Nodes (54): gcs_invalidate_validation(), gcs_publish_validation(), gcs_verify_upload(), gds_apply_plan(), gds_delete_file(), gds_download(), gds_find_protected(), gds_list_archives() (+46 more)

### Community 1 - "setup.sh"
Cohesion: 0.10
Nodes (51): detect_os_family(), os_detect.sh script, checkAddonsPathOnOdooConfFile(), checkGitRepositories(), checkImportantEnvVariable(), checkRegistryConnection(), COLOR_ERROR, COLOR_INFO (+43 more)

### Community 2 - "Critical Workflows"
Cohesion: 0.05
Nodes (37): Agent Instructions, Agent Personas (Routing), Core Checklist, Example, Required Protocol, Agent Personas — Full Reference, Behavior, @flash — Precise Execution Agent (+29 more)

### Community 3 - "restore-snapshot.sh"
Cohesion: 0.16
Nodes (33): odoo_utils.sh script, trigger_registry_reload(), areYouReallySure(), check_git_ssh_access(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS (+25 more)

### Community 4 - "ssh_utils.sh"
Cohesion: 0.10
Nodes (31): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, log() (+23 more)

### Community 5 - "dataodoo-backupper.sh"
Cohesion: 0.19
Nodes (20): areYouReallySure(), checkOdooEndpoint(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler() (+12 more)

### Community 6 - "filestore-manager.sh"
Cohesion: 0.21
Nodes (21): build_classification_cte(), cmd_clean_assets(), cmd_clean_missing(), cmd_clean_orphans(), cmd_list(), cmd_summary(), COLOR_ERROR, COLOR_INFO (+13 more)

### Community 7 - "scripts/README.md"
Cohesion: 0.09
Nodes (22): Backup Data, Database Cloner, Delete snapshots keeping the latest 10, Download Snapshot, Dry-run deletion simulation, Dry-run preview without uploading or deleting, Filestore Manager, Generate key interactively or using .env PRD_SSH_HOST (+14 more)

### Community 8 - "git_addons_updater.sh"
Cohesion: 0.20
Nodes (16): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), is_repo_ignored(), isDirectoryGitRepository() (+8 more)

### Community 9 - "git_odoo-base_updater.sh"
Cohesion: 0.20
Nodes (16): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), is_repo_ignored(), isDirectoryGitRepository() (+8 more)

### Community 10 - ".uninstall-odoo.sh"
Cohesion: 0.23
Nodes (18): areYouReallySure(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, die(), error_handler() (+10 more)

### Community 11 - "Maintenance"
Cohesion: 0.11
Nodes (17): 1. Enable Multi-Deployment, 2. Create Deployment Profiles, 3. Switch Between Deployments, Automatic Credential Generation, Check the git repository for custom addons used by Docker Image, Check the version of Odoo base, Configuration, Configuration (+9 more)

### Community 12 - "install-snapshot.sh"
Cohesion: 0.22
Nodes (17): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler() (+9 more)

### Community 13 - "long-process-mode.sh"
Cohesion: 0.22
Nodes (16): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, disable_long_process_mode(), enable_long_process_mode(), error_handler() (+8 more)

### Community 14 - "dataodoo-remover.sh"
Cohesion: 0.21
Nodes (15): areYouReallySure(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log() (+7 more)

### Community 15 - "download-snapshot.sh"
Cohesion: 0.21
Nodes (15): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, get_gdrive_access_token_from_sa(), is_gdrive_token_valid(), log() (+7 more)

### Community 16 - "install-databasecloner.sh"
Cohesion: 0.22
Nodes (16): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler() (+8 more)

### Community 17 - "install-deploy_release_candidate.sh"
Cohesion: 0.22
Nodes (16): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler() (+8 more)

### Community 18 - "queue_lock.sh"
Cohesion: 0.19
Nodes (12): __ql_beat(), _ql_log(), __ql_release(), _ql_remote_call(), _ql_start_local_heartbeat(), _ql_start_remote_heartbeat(), queue_lock_acquire_local(), queue_lock_acquire_remote() (+4 more)

### Community 19 - "utilities/install-font.sh"
Cohesion: 0.27
Nodes (16): check_dependencies(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), get_filename() (+8 more)

### Community 20 - "cleanup-snapshot.sh"
Cohesion: 0.23
Nodes (15): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, get_gdrive_access_token_from_sa(), is_gdrive_token_valid(), log() (+7 more)

### Community 21 - "install-docker_logs_rotator.sh"
Cohesion: 0.23
Nodes (14): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), installLogrotator(), log() (+6 more)

### Community 22 - "list-snapshot.sh"
Cohesion: 0.21
Nodes (15): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, get_gdrive_access_token_from_sa(), is_gdrive_token_valid(), log() (+7 more)

### Community 23 - "entrypoint.sh"
Cohesion: 0.24
Nodes (14): add_arg(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log() (+6 more)

### Community 24 - "change-snapshot-remote.sh"
Cohesion: 0.22
Nodes (14): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, log() (+6 more)

### Community 25 - "dataodoo-password_changer.sh"
Cohesion: 0.23
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 26 - "generate_map.sh"
Cohesion: 0.26
Nodes (14): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), executeCommand(), log() (+6 more)

### Community 27 - "scripts/install-font.sh"
Cohesion: 0.30
Nodes (14): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), load_dotenv(), log() (+6 more)

### Community 28 - "install-backupdata.sh"
Cohesion: 0.26
Nodes (14): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), install_script(), log() (+6 more)

### Community 29 - "install-restore_backupdata.sh"
Cohesion: 0.26
Nodes (14): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), install_script(), log() (+6 more)

### Community 30 - "install_sudoers.sh"
Cohesion: 0.25
Nodes (14): append_sudoers_rule(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log() (+6 more)

### Community 31 - "test_deploy_release_candidate.sh"
Cohesion: 0.16
Nodes (9): assert_contains(), assert_not_contains(), log_info(), PATH, test_deploy_release_candidate.sh script, TEST_COLOR_FAIL, TEST_COLOR_INFO, TEST_COLOR_RESET (+1 more)

### Community 32 - "setup_nginx_cache_conf.sh"
Cohesion: 0.23
Nodes (12): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+4 more)

### Community 33 - "setup_nginx_security_conf.sh"
Cohesion: 0.24
Nodes (12): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+4 more)

### Community 34 - "add_hostname_to_btop_titlebar.sh"
Cohesion: 0.25
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 35 - "install-code_server.sh"
Cohesion: 0.25
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 36 - "uninstall-code_server.sh"
Cohesion: 0.24
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 37 - "uninstall-snapshot.sh"
Cohesion: 0.24
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 38 - "rename_project.sh"
Cohesion: 0.24
Nodes (12): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+4 more)

### Community 39 - "switch_env.sh"
Cohesion: 0.25
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 40 - "transfer_pg_ownership.sh"
Cohesion: 0.25
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 41 - "update-env-file.sh"
Cohesion: 0.25
Nodes (13): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+5 more)

### Community 42 - "update-odoo-config.sh"
Cohesion: 0.27
Nodes (12): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log(), log_error() (+4 more)

### Community 43 - "bump_image_version.sh"
Cohesion: 0.27
Nodes (11): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, log(), log_error(), log_info() (+3 more)

### Community 44 - "install-dump_database.sh"
Cohesion: 0.30
Nodes (11): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, install_script(), log(), log_error(), log_info() (+3 more)

### Community 45 - "install-export_filestore.sh"
Cohesion: 0.30
Nodes (11): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, install_script(), log(), log_error(), log_info() (+3 more)

### Community 46 - "change_database.sh"
Cohesion: 0.33
Nodes (9): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, log(), log_error(), log_info(), log_success() (+1 more)

### Community 47 - "disk_free_monitor.sh"
Cohesion: 0.33
Nodes (9): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, log(), log_error(), log_info(), log_success() (+1 more)

### Community 48 - "update-deployment-tool.sh"
Cohesion: 0.33
Nodes (9): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, log(), log_error(), log_info(), log_success() (+1 more)

### Community 49 - "get-code-server-env.sh"
Cohesion: 0.28
Nodes (7): COLOR_ERROR, COLOR_INFO, COLOR_RESET, log(), log_error(), log_info(), get-code-server-env.sh script

### Community 50 - "list-databases.sh"
Cohesion: 0.33
Nodes (7): COLOR_ERROR, COLOR_INFO, COLOR_RESET, log(), log_error(), log_info(), list-databases.sh script

### Community 52 - "validate-agent-config.sh"
Cohesion: 0.60
Nodes (5): fail(), log(), ok(), validate-agent-config.sh script, warn()

### Community 53 - "Phased Execution"
Cohesion: 0.40
Nodes (4): builder — Edit mode, investigator — Locate mode, Phased Execution, reviewer — Review mode

## Knowledge Gaps
- **330 isolated node(s):** `COLOR_RESET`, `COLOR_INFO`, `COLOR_SUCCESS`, `COLOR_WARN`, `COLOR_ERROR` (+325 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **14 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `COLOR_RESET`, `COLOR_INFO`, `COLOR_SUCCESS` to the rest of the system?**
  _330 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `snapshot_storage.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.05827505827505827 - nodes in this community are weakly interconnected._
- **Should `setup.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.103424178895877 - nodes in this community are weakly interconnected._
- **Should `Critical Workflows` be split into smaller, more focused modules?**
  _Cohesion score 0.047619047619047616 - nodes in this community are weakly interconnected._
- **Should `ssh_utils.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.10416666666666667 - nodes in this community are weakly interconnected._
- **Should `scripts/README.md` be split into smaller, more focused modules?**
  _Cohesion score 0.08695652173913043 - nodes in this community are weakly interconnected._
- **Should `Maintenance` be split into smaller, more focused modules?**
  _Cohesion score 0.1111111111111111 - nodes in this community are weakly interconnected._