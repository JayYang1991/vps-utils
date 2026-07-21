# AGENTS.md

This repository contains bash scripts for installing V2Ray and managing sing-box proxy workflows on Linux systems following FHS standards.

## Build/Lint/Test Commands

### Linting
```bash
# Run shellcheck on all scripts
shellcheck install-*.sh

# Format with shfmt (uses -i 2 -ci -sr options)
shfmt -i 2 -ci -sr -w install-*.sh

# Lint switcher script explicitly
shellcheck switch-singbox-proxy.sh
shfmt -i 2 -ci -sr -w switch-singbox-proxy.sh
```

### Testing
```bash
# Full installation test (requires sudo)
sudo bash install-release.sh
sudo bash install-release.sh --check
sudo bash install-dat-release.sh

# Run specific script tests
sudo bash install-v2ray-proxy-server.sh
sudo bash install-v2ray-proxy-client.sh
sudo bash install-v2ray-reverse-server.sh

# Sing-box proxy switch check
bash switch-singbox-proxy.sh --show
bash switch-singbox-proxy.sh --best

# Note: There are no unit tests. Testing is done by running scripts directly.
# Tests are run in CI via .github/workflows/sh-checker.yml on Ubuntu, Rocky Linux, and Arch Linux.
```

## Code Style Guidelines

### Shebang and Headers
- Always use `#!/usr/bin/env bash` as shebang
- Include shellcheck directives after shebang: `# shellcheck disable=SC2268`
- Add URL references and variable documentation comments at the top
- Include license or copyright notice if applicable

### Variable Naming
- **Constants/Paths**: UPPER_CASE (e.g., `DAT_PATH`, `JSON_PATH`)
- **Local variables**: lower_case (e.g., `v2ray_daemon_to_stop`, `get_ver_exit_code`)
- **Functions**: snake_case (e.g., `check_if_running_as_root`, `identify_the_operating_system_and_architecture`)
- Use default value syntax for configurable variables: `DAT_PATH=${DAT_PATH:-/usr/local/share/v2ray}`
- Avoid using reserved words as variable names

### Formatting
- Indentation: 2 spaces (enforced by shfmt)
- Case statements: indented by 2 spaces for options
- Use double quotes around all variable references: `"$VARIABLE"`
- Prefer `[[ ]]` over `[ ]` for tests
- Consistent spacing around operators: `[[ "$VAR" == 'value' ]]`
- No trailing whitespace in lines

### Error Handling
- Always prefix error messages with `error:` and info messages with `info:`
- Use `exit 1` for errors, `exit 0` for success
- Functions return meaningful exit codes (0=success, 1=failure, 2=other)
- Check command success with `$?` or direct conditional checks
- Use `set -e` at script level for immediate exit on error
- Provide meaningful error messages with context

### Output Formatting
- Use tput for colored output: `red=$(tput setaf 1)`, `green=$(tput setaf 2)`, `aoi=$(tput setaf 6)`, `reset=$(tput sgr0)`
- Prefix installed/removed files with descriptive labels
- Use `echo` for output, avoid `printf` unless necessary
- Consistent logging format across scripts

### Function Structure
- Keep functions focused on single responsibilities
- Use `local` for variables that should not leak
- Comment functions to explain their purpose above the definition
- Function names should be descriptive verb phrases
- Include parameter documentation in comments
- Use `return` for function exit codes

### Shellcheck Compliance
- All scripts must pass shellcheck
- Add `# shellcheck disable=...` directives only when necessary
- Fix warnings rather than suppressing them when possible
- Regularly run shellcheck during development

### curl Wrapper
- Define a custom `curl()` function with retry logic at script level
- Always use: `$(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60`
- Include proper user-agent and timeout settings

### System Integration
- Follow Filesystem Hierarchy Standard (FHS)
- Use systemd for service management
- Check for systemd-analyze capabilities before using
- Stop services before updating/removing
- Use proper service naming conventions

### Code Organization
- Main execution logic in `main()` function
- Call `main "$@"` at end of script
- Group related functions together
- Place configuration variables at top of file
- Separate concerns into logical sections

### Conditional Logic
- Use `case` statements for multiple value matching (e.g., OS/arch detection)
- Prefer `[[ ]]` with `=` and `=~` operators over `[ ]`
- Use `||` and `&&` for simple conditional execution
- Quote string literals in comparisons: `[[ "$VAR" == 'value' ]]`

### Comments
- Add inline comments explaining non-obvious logic
- Use `#` for comments (preferable over `:` for documentation)
- Comment configurable variables with usage examples
- Include URL references in file headers
- Document complex algorithms or workarounds

### File Operations
- Quote paths with spaces: `rm -r "$PATH"`
- Use `"rm"` to avoid shell built-in conflicts
- Check file existence before operations: `[[ -f 'file' ]]`
- Create temp directories with `mktemp -d`
- Clean up temporary files in error conditions

## Common Patterns

### OS Detection
Use consistent pattern for OS/arch detection via `case` statements matching `$(uname -m)`

### Package Manager Detection
Set `PACKAGE_MANAGEMENT_INSTALL` and `PACKAGE_MANAGEMENT_REMOVE` based on OS distro

### Version Checking
Use `get_version()` returning 0=install/update, 1=current latest, 2=no update

## Environment Variables

### Configurable Paths
Override via environment: `DAT_PATH` (/usr/local/share/v2ray), `JSON_PATH` (/usr/local/etc/v2ray), `JSONS_PATH`, `check_all_service_files`

### Client-Specific Variables
Set before running proxy/reverse scripts: `V2RAY_PROXY_SERVER_IP`, `V2RAY_PROXY_ID`, `V2RAY_REVERSE_SERVER_IP`, `V2RAY_REVERSE_ID`

### Sing-box Switch Variables
Optional for `switch-singbox-proxy.sh`: `TEST_URL` (probe URL, default `https://www.gstatic.com/generate_204`), `TEST_TIMEOUT_MS` (probe timeout in milliseconds, default `5000`)

## Repository Structure

- `install-release.sh`: Main V2Ray installation (649 lines)
- `install-v2ray-proxy-server.sh`: Proxy server installation
- `install-v2ray-proxy-client.sh`: Proxy client installation
- `install-v2ray-reverse-server.sh`: Reverse server installation
- `install-dat-release.sh`: Dat file update script (83 lines)
- `switch-singbox-proxy.sh`: sing-box group switch tool (supports lowest-latency auto-select)
- `.github/workflows/sh-checker.yml`: CI configuration
- `*_config.json`: Example configurations

## Sing-box Proxy Switching Pattern

- Default action of `switch-singbox-proxy.sh` is `--best` (auto-select lowest-latency node in a group)
- `--next` keeps round-robin switching behavior
- Delay probing uses Clash API endpoint: `GET /proxies/{name}/delay?url=<url>&timeout=<ms>`
- Manual pinning is supported with `--set <node_name>`

## Service Management Pattern

Always stop services before updating. Check for `v2ray@` daemon instances:
```bash
V2RAY_CUSTOMIZE="$(systemctl list-units | grep 'v2ray@' | awk -F ' ' '{print $1}')"
local v2ray_daemon_to_stop="${V2RAY_CUSTOMIZE:-v2ray.service}"
systemctl stop "$v2ray_daemon_to_stop"
```

## Development Workflow

1. Make changes to scripts
2. Run linting: `shellcheck install-*.sh switch-singbox-proxy.sh && shfmt -i 2 -ci -sr -w install-*.sh switch-singbox-proxy.sh`
3. Test changes: `sudo bash install-release.sh --check` and `bash switch-singbox-proxy.sh --show`
4. Commit changes with descriptive messages
5. Push to repository

## Security Considerations

- Never expose sensitive information in error messages
- Use secure temporary file creation
- Validate all user inputs
- Follow principle of least privilege
- Use HTTPS for all external downloads
