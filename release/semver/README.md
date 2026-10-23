# release/semver

Calculates the next semver version from Conventional Commits and creates a tag and GitHub release.

Wraps [semantic-release](https://semantic-release.gitbook.io/) with the `conventionalcommits` preset.

## Usage

```yaml
- uses: pippiio/actions/release/semver@v1
```

## Versioning

| Commit prefix | Result |
| --- | --- |
| `feat!:` | major |
| `feat:` | minor |
| `fix:` | patch |
| `chore:`, `refactor:`, `docs:` | no release |

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `dry-run` | No | `false` | Calculate the version without creating a tag or release |

## Outputs

| Name | Description |
| --- | --- |
| `new-release-published` | Whether a new release was published |
| `new-release-version` | The version that was released |

## Requirements

The calling workflow needs `contents: write` to create tags and releases.

Repositories using squash merge must have PR titles in Conventional Commits format, since the PR title becomes the commit message.