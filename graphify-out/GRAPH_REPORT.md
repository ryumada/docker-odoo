# Graph Report - docker-odoo  (2026-11-13)

## Corpus Check
- 123 files · ~141,219 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1544 nodes · 2611 edges · 107 communities (80 shown, 27 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 12 edges (avg confidence: 0.5)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `0459adce`
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
- test_drill_defaults.sh
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
- change_faketime.sh
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
- validate-snapshot.sh
- validate-agent-config.sh
- Phased Execution
- knowledge/README.md
- how-to-scan-repository.md
- ponytail-ref.md
- conf/README.md
- git/README.md
- lib.sh
- create-deployment-dir.sh
- generate-deploy-rc-ssh-key.sh
- git-helper.sh
- check_odoo_health.sh
- filter_odoo_log.sh
- read-config-file.sh
- save-config-file.sh
- bash-script-template.sh
- utilities/README.md
- test_restore_snapshot.sh
- test_secret_args.sh
- test_validator_inbox.sh
- test_local_retention.sh
- test_odoo_sizes.sh
- test_snapshot_stats.sh
- test_reverse_proxy.sh
- Handler
- setup-validator-docker.sh
- validate-snapshot-worker.sh
- test_read_drill_reports.sh
- suite_worker.sh
- Done
- docker
- suite_remote.sh
- suite_version.sh
- Handler
- suite_storage.sh
- odoo_version.sh
- Handler
- fake_odoo_bin.py
- gcloud
- mkfixture.sh
- suite_credentials.sh
- suite_boot.sh
- suite_setup.sh
- suite_formats.sh
- suite_local.sh
- suite_rootless.sh
- read-drill-reports.sh
- test_validate_snapshot.sh
- df

## God Nodes (most connected - your core abstractions)
1. `main()` - 27 edges
2. `validate-snapshot.sh script` - 23 edges
3. `record_stage()` - 22 edges
4. `log_info()` - 21 edges
5. `log_error()` - 19 edges
6. `log_info()` - 19 edges
7. `restoreSnapshotFull()` - 18 edges
8. `log_error()` - 18 edges
9. `finish()` - 17 edges
10. `log_success()` - 16 edges

## Surprising Connections (you probably didn't know these)
- `verifySnapshotChecksum()` --calls--> `snap_verify_file()`  [EXTRACTED]
  scripts/restore-snapshot.sh → scripts/lib/snapshot_storage.sh
- `download-snapshot.sh script` --calls--> `gds_download()`  [EXTRACTED]
  scripts/download-snapshot.sh → scripts/lib/snapshot_storage.sh
- `download-snapshot.sh script` --calls--> `snap_write_sidecar()`  [EXTRACTED]
  scripts/download-snapshot.sh → scripts/lib/snapshot_storage.sh
- `cleanup-snapshot.sh script` --calls--> `snap_local_retention()`  [EXTRACTED]
  scripts/cleanup-snapshot.sh → scripts/lib/snapshot_storage.sh
- `generate-snapshot-ssh-key.sh script` --calls--> `install_pubkey_via_admin()`  [EXTRACTED]
  scripts/generate-snapshot-ssh-key.sh → scripts/lib/ssh_utils.sh

## Import Cycles
- None detected.

## Communities (107 total, 27 thin omitted)

### Community 0 - "snapshot_storage.sh"
Cohesion: 0.05
Nodes (63): gcs_invalidate_validation(), gcs_publish_validation(), gcs_verify_upload(), gds_apply_plan(), gds_curl(), gds_delete_file(), gds_download(), gds_find_by_name() (+55 more)

### Community 1 - "setup.sh"
Cohesion: 0.10
Nodes (52): detect_os_family(), os_detect.sh script, checkAddonsPathOnOdooConfFile(), checkGitRepositories(), checkImportantEnvVariable(), checkRegistryConnection(), COLOR_ERROR, COLOR_INFO (+44 more)

### Community 2 - "Critical Workflows"
Cohesion: 0.05
Nodes (37): Agent Instructions, Agent Personas (Routing), Core Checklist, Example, Required Protocol, Agent Personas — Full Reference, Behavior, @flash — Precise Execution Agent (+29 more)

### Community 3 - "restore-snapshot.sh"
Cohesion: 0.15
Nodes (37): odoo_utils.sh script, trigger_registry_reload(), areYouReallySure(), check_bundled_directories_present(), check_git_ssh_access(), check_restore_errors(), COLOR_ERROR, COLOR_INFO (+29 more)

### Community 4 - "ssh_utils.sh"
Cohesion: 0.07
Nodes (45): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, log() (+37 more)

### Community 5 - "dataodoo-backupper.sh"
Cohesion: 0.19
Nodes (20): areYouReallySure(), checkOdooEndpoint(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler() (+12 more)

### Community 6 - "filestore-manager.sh"
Cohesion: 0.21
Nodes (21): build_classification_cte(), cmd_clean_assets(), cmd_clean_missing(), cmd_clean_orphans(), cmd_list(), cmd_summary(), COLOR_ERROR, COLOR_INFO (+13 more)

### Community 7 - "scripts/README.md"
Cohesion: 0.04
Nodes (46): 1. Enable Multi-Deployment, 2. Create Deployment Profiles, 3. Switch Between Deployments, Automatic Credential Generation, Automatic Validation & Worker Cron, Check the git repository for custom addons used by Docker Image, Check the version of Odoo base, Configuration (+38 more)

### Community 8 - "git_addons_updater.sh"
Cohesion: 0.20
Nodes (16): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), is_repo_ignored(), isDirectoryGitRepository() (+8 more)

### Community 9 - "git_odoo-base_updater.sh"
Cohesion: 0.20
Nodes (16): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), is_repo_ignored(), isDirectoryGitRepository() (+8 more)

### Community 10 - ".uninstall-odoo.sh"
Cohesion: 0.23
Nodes (18): areYouReallySure(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, die(), error_handler() (+10 more)

### Community 11 - "test_drill_defaults.sh"
Cohesion: 0.18
Nodes (12): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_eq(), check_has(), fail() (+4 more)

### Community 12 - "install-snapshot.sh"
Cohesion: 0.22
Nodes (19): COLOR_BOLD, COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler() (+11 more)

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
Cohesion: 0.21
Nodes (16): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, get_gdrive_access_token_from_sa(), is_gdrive_token_valid(), log() (+8 more)

### Community 21 - "install-docker_logs_rotator.sh"
Cohesion: 0.23
Nodes (14): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), installLogrotator(), log() (+6 more)

### Community 22 - "list-snapshot.sh"
Cohesion: 0.21
Nodes (15): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, get_gdrive_access_token_from_sa(), is_gdrive_token_valid(), log() (+7 more)

### Community 23 - "entrypoint.sh"
Cohesion: 0.24
Nodes (14): add_arg(), COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, error_handler(), log() (+6 more)

### Community 24 - "change_faketime.sh"
Cohesion: 0.33
Nodes (9): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, log(), log_error(), log_info(), log_success() (+1 more)

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
Cohesion: 0.18
Nodes (11): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, log(), log_error(), log_info(), log_success() (+3 more)

### Community 48 - "update-deployment-tool.sh"
Cohesion: 0.33
Nodes (9): COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, log(), log_error(), log_info(), log_success() (+1 more)

### Community 49 - "get-code-server-env.sh"
Cohesion: 0.28
Nodes (7): COLOR_ERROR, COLOR_INFO, COLOR_RESET, log(), log_error(), log_info(), get-code-server-env.sh script

### Community 50 - "list-databases.sh"
Cohesion: 0.33
Nodes (7): COLOR_ERROR, COLOR_INFO, COLOR_RESET, log(), log_error(), log_info(), list-databases.sh script

### Community 51 - "validate-snapshot.sh"
Cohesion: 0.05
Nodes (68): boot_layout(), boot_prepare(), boot_run(), cat_member(), check_disk(), cleanup(), COLOR_ERROR, COLOR_INFO (+60 more)

### Community 52 - "validate-agent-config.sh"
Cohesion: 0.60
Nodes (5): fail(), log(), ok(), validate-agent-config.sh script, warn()

### Community 53 - "Phased Execution"
Cohesion: 0.40
Nodes (4): builder — Edit mode, investigator — Locate mode, Phased Execution, reviewer — Review mode

### Community 59 - "lib.sh"
Cohesion: 0.06
Nodes (27): check(), check_eq(), check_grep(), check_no_grep(), check_not(), check_rc(), drive_start(), drive_stop() (+19 more)

### Community 73 - "test_restore_snapshot.sh"
Cohesion: 0.11
Nodes (19): as_pg(), C_FAIL, C_INFO, C_PASS, C_RESET, check_eq(), check_grep(), cleanup() (+11 more)

### Community 74 - "test_secret_args.sh"
Cohesion: 0.12
Nodes (15): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check(), check_eq(), fail() (+7 more)

### Community 75 - "test_validator_inbox.sh"
Cohesion: 0.15
Nodes (19): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_eq(), fail(), handoff() (+11 more)

### Community 76 - "test_local_retention.sh"
Cohesion: 0.13
Nodes (14): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_eq(), cleanup(), fail() (+6 more)

### Community 77 - "test_odoo_sizes.sh"
Cohesion: 0.15
Nodes (17): as_pg(), C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_eq(), check_grep() (+9 more)

### Community 78 - "test_snapshot_stats.sh"
Cohesion: 0.15
Nodes (16): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_eq(), fail(), lib() (+8 more)

### Community 80 - "test_reverse_proxy.sh"
Cohesion: 0.20
Nodes (16): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_proxy(), fail(), odoo_would_run_queue_job() (+8 more)

### Community 81 - "Handler"
Cohesion: 0.27
Nodes (8): BaseHTTPRequestHandler, files_dir(), Handler, load_all(), main(), parse_q(), Supports the clauses the scripts send, joined by ' and '., save_file()

### Community 83 - "setup-validator-docker.sh"
Cohesion: 0.18
Nodes (16): COLOR_CYAN, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN, git_valid_remote(), log() (+8 more)

### Community 84 - "validate-snapshot-worker.sh"
Cohesion: 0.13
Nodes (15): _drill_is_local_name(), _drill_is_loopback(), drill_defaults.sh script, COLOR_ERROR, COLOR_INFO, COLOR_RESET, COLOR_SUCCESS, COLOR_WARN (+7 more)

### Community 85 - "test_read_drill_reports.sh"
Cohesion: 0.23
Nodes (12): C_FAIL, C_INFO, C_PASS, C_RESET, C_SKIP, check_eq(), fail(), pass() (+4 more)

### Community 86 - "suite_worker.sh"
Cohesion: 0.22
Nodes (7): age_reports(), check_wk(), inbox_put(), local_put(), suite_worker.sh script, suite_worker(), wk()

### Community 87 - "Done"
Cohesion: 0.15
Nodes (12): Done, For the owner (not code), Odoo addon, Open, Problems that already existed, Security, Snapshot side, Snapshot side (+4 more)

### Community 88 - "docker"
Cohesion: 0.31
Nodes (5): docker script, as_pg(), cdir_of(), odoo_run(), pg_stop()

### Community 89 - "suite_remote.sh"
Cohesion: 0.33
Nodes (7): ps_sampler(), remote_bundles_gone(), remote_clean(), remote_setup(), remote_validator_gone(), suite_remote.sh script, suite_remote()

### Community 90 - "suite_version.sh"
Cohesion: 0.31
Nodes (7): backup_fallback_manifest(), log_info(), log_warn(), suite_version.sh script, snap_version(), suite_version(), ver_release_py()

### Community 92 - "suite_storage.sh"
Cohesion: 0.33
Nodes (3): gcs(), suite_storage.sh script, suite_storage()

### Community 93 - "odoo_version.sh"
Cohesion: 0.40
Nodes (3): odoo_version_detect(), _odoo_version_log(), odoo_version.sh script

### Community 98 - "suite_credentials.sh"
Cohesion: 0.50
Nodes (3): make_curl_spy(), suite_credentials.sh script, suite_credentials()

## Knowledge Gaps
- **435 isolated node(s):** `COLOR_RESET`, `COLOR_INFO`, `COLOR_SUCCESS`, `COLOR_WARN`, `COLOR_ERROR` (+430 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **27 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `COLOR_RESET`, `COLOR_INFO`, `COLOR_SUCCESS` to the rest of the system?**
  _435 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `snapshot_storage.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.05052631578947368 - nodes in this community are weakly interconnected._
- **Should `setup.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.10235690235690235 - nodes in this community are weakly interconnected._
- **Should `Critical Workflows` be split into smaller, more focused modules?**
  _Cohesion score 0.047619047619047616 - nodes in this community are weakly interconnected._
- **Should `restore-snapshot.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.14750290360046459 - nodes in this community are weakly interconnected._
- **Should `ssh_utils.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.0700354609929078 - nodes in this community are weakly interconnected._
- **Should `scripts/README.md` be split into smaller, more focused modules?**
  _Cohesion score 0.041666666666666664 - nodes in this community are weakly interconnected._