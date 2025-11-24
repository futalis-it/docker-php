# curl Update Automation

This directory contains scripts for automating curl package updates from Alpine Linux aports.

## Overview

The automation system tracks the Alpine Linux curl package and helps apply updates to our templated APKBUILD, while preserving custom template conditionals for different PHP versions.

### Files

- **check-curl-updates.sh** - Detects new curl versions/patches from Alpine GitLab
- **apply-curl-update.sh** - Applies updates automatically (safe sections only)
- **.curl-upstream-state.json** - Tracks last checked commit and version

## Usage

### Manual Check

Check for updates manually:

```bash
./scripts/check-curl-updates.sh
```

This will:
- Fetch latest curl APKBUILD from Alpine GitLab
- Compare with local version
- Show new commits since last check
- Update state file
- Prompt to apply update if available (interactive mode)

### Apply Update

Apply a specific version update:

```bash
./scripts/apply-curl-update.sh 8.18.0 0
```

This will:
- Create a new git branch: `curl-update-8.18.0-r0`
- Update `pkgver` and `pkgrel` in template
- Sync patch files (download new, remove obsolete)
- Update `source` array and `sha512sums`
- Run `apply-templates.sh` to regenerate all Dockerfiles
- Create a commit with checklist

### Automated (CI)

The GitHub Actions workflow `.github/workflows/check-curl-updates.yml`:
- Runs daily at 10:00 UTC
- Can be triggered manually via workflow_dispatch
- Automatically creates a PR when updates are detected

## What Gets Automated

### ✅ 100% Automated
- Version updates (`pkgver`, `pkgrel`)
- Patch file synchronization
- Source array updates
- Checksum updates (`sha512sums`)
- Dockerfile regeneration via `apply-templates.sh`

### ⚠️ Manual Review Required
These sections contain template conditionals and need manual review:

1. **depends_dev** (lines 23-29 in curl/APKBUILD)
   - PHP 8.0 uses `openssl1.1-compat-dev` (not `openssl-dev>3`)
   - PHP 8.0 excludes `nghttp2-dev` and `nghttp3-dev`

2. **checkdepends** (line 33)
   - PHP 8.0 excludes `nghttp2` dependency

3. **build() function** (lines 239-243)
   - PHP 8.0 excludes `--with-nghttp2`, `--with-nghttp3`, `--with-openssl-quic`

4. **secfixes**
   - New CVE entries (script alerts but doesn't merge automatically)

## Workflow

### When Update Available

1. **Automated**: Script creates branch and commits automated changes
2. **Manual**: Review template-conditional sections
3. **Manual**: Compare with upstream: `diff -u curl/APKBUILD /tmp/upstream-curl-APKBUILD`
4. **Manual**: Test builds for PHP 8.0 and PHP 8.3+
5. **Manual**: Push branch and create/merge PR

### Testing Builds

After applying updates, test that template conditionals work correctly:

```bash
# Test PHP 8.0 (should NOT have HTTP/3 support)
docker build -f 8.0/alpine3.20/cli/Dockerfile -t test-php80-curl .
docker run --rm test-php80-curl curl --version | grep -E "nghttp|quic"

# Test PHP 8.3 (should have HTTP/3 support)
docker build -f 8.3/alpine3.21/cli/Dockerfile -t test-php83-curl .
docker run --rm test-php83-curl curl --version | grep -E "nghttp|quic"
```

Expected results:
- PHP 8.0: No `nghttp2`, `nghttp3`, or `HTTP/3` in output
- PHP 8.3+: Should show `nghttp2`, `nghttp3`, and `HTTP/3` support

## Template Conditionals

Our `curl/APKBUILD` uses jq-template syntax to support different PHP versions:

```jq
{{ if env.version != "8.0" then ( -}}
	nghttp2-dev
{{ ) else "" end -}}
```

These conditionals are preserved by the update scripts. When upstream makes changes to these sections, you must:

1. Review the diff: `diff -u curl/APKBUILD /tmp/upstream-curl-APKBUILD`
2. Manually merge changes while preserving `{{ if }}` blocks
3. Test both PHP 8.0 and 8.3+ builds

## State File

`.curl-upstream-state.json` stores:
```json
{
  "last_commit": "5974f859...",
  "last_version": "8.17.0",
  "last_pkgrel": "1",
  "checked_at": "2025-11-24T10:00:00Z"
}
```

This prevents duplicate checks and tracks what we've already seen.

## Upstream Sources

- **Alpine aports**: https://gitlab.alpinelinux.org/alpine/aports/-/tree/master/main/curl
- **GitLab API**: https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports
- **curl upstream**: https://curl.se/

## Troubleshooting

### Script fails to fetch from GitLab

Check network connectivity and GitLab API status:
```bash
curl -s "https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports/repository/commits?path=main/curl&per_page=1"
```

### Patches fail to download

The script uses URL encoding for patch filenames. Check:
```bash
# Test patch download manually
PATCH="reg-19383.patch"
curl -s "https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports/repository/files/main%2Fcurl%2F${PATCH}?ref=master" | jq -r '.content' | base64 -d
```

### Template conditionals broken after update

If automated merge corrupted template syntax:
1. Restore template: `git checkout HEAD -- curl/APKBUILD`
2. Apply changes manually
3. Validate syntax by running: `./apply-templates.sh`

### GitHub Actions workflow not triggering

Check:
- Workflow file syntax: `.github/workflows/check-curl-updates.yml`
- Cron schedule: `0 10 * * *` (daily at 10:00 UTC)
- Repository permissions: workflow needs `contents: write` and `pull-requests: write`

## Security Considerations

- All API calls use HTTPS
- No authentication tokens stored (Alpine GitLab is public)
- Scripts run with user permissions (no sudo required)
- All changes committed to git (auditable)
- PR review required before merge

## Future Enhancements

Potential improvements:
- Email/Slack notifications on new updates
- Automated build testing in CI
- Smart merge for template-conditional sections
- Integration with Renovate or Dependabot
- Track multiple Alpine branches (edge, 3.21, etc.)