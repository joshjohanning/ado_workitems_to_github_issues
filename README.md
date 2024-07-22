# ado_workitems_to_github_issues

PowerShell script to migrate Azure DevOps work items to GitHub Issues

### Prerequisites

1. Install az devops and github cli where this is running (ie: action or locally; GitHub-hosted runners already have)
2. In GitHub, [create a label](https://docs.github.com/en/issues/using-labels-and-milestones-to-track-work/managing-labels) for EACH work item type that is being migrated (as lower case) 
    - ie: "user story", "bug", "task", "feature"
3. Define under what area path you want to migrate
    - You can modify the WIQL if you want to use a different way to migrate work items, such as `[TAG] = "migrate"`

### Things it migrates

1. Title
2. Description (or for a bug, repro steps and/or system info)
3. State (if the work item is done / closed, it will be closed in GitHub)
4. It will try to assign the work item to the correct user in GitHub - based on ADO email before the `@`
    - This uses the `-gh_update_assigned_to` and `-gh_assigned_to_user_suffix` options
    - Users have to be added to GitHub org
5. Migrate acceptance criteria as part of issue body (if present)
6. Adds in the following as a comment to the issue:
    - Original work item url 
    - Basic details in a collapsed markdown table
    - Entire work item as JSON in a collapsed section
7. Creates tag "copied-to-github" and a comment on the ADO work item with `-$ado_production_run $true"`. The tag prevents duplicate copying.

### To Do
1. Provide user mapping option

### Things it won't ever migrate
1. Created date/update dates

### Example

- [Screenshot](https://user-images.githubusercontent.com/19912012/157745772-69f5cf75-5407-491e-a754-d94b188378ff.png)
- [Migrated GitHub Issue](https://github.com/joshjohanning-org/migrate-ado-workitems/issues/296)

## Instructions for Running in Actions

The recommendation is to use a GitHub App to run the migration - a GitHub app has higher rate limits than using a user PAT.

1. Create GitHub App with (can use this [reference](https://josh-ops.com/posts/github-apps/#creating-a-github-app)). Use the following permissions:
    + Repo: `Contents:Read`
    + Repo: `Issues:Read and write`
    + Org: `Members:Read`
1. Create Private Key for GitHub App
1. Obtain App ID and Installation ID - see [the instructions for using smee.io](https://josh-ops.com/posts/github-apps/#creating-a-github-app)
1. Create the following action secrets:
    + `ADO_PAT`: Azure DevOps PAT with appropriate permissions to read work and write items
    + `PRIVATE_KEY`: The contents of the private key created and downloaded in step #2
1. Use the [action](.github/workflows/migrate-work-items.yml) and update the App ID and Installation ID obtained in step #3
1. Update any defaults in the [action](.github/workflows/migrate-work-items.yml) (ie: Azure DevOps organization and project, GitHub organization and repo)
1. Ensure the action exists in the repo's default branch
1. Run the workflow

## Instructions for Running Locally

Using the GitHub app might be better so you don't reach a limit on your GitHub account on creating new issues 😀

```pwsh
./ado_workitems_to_github_issues.ps1 `
    -ado_pat "abc" `
    -ado_org "jjohanning0798" `
    -ado_project "PartsUnlimited" `
    -ado_area_path "PartsUnlimited\migrate" `
    -ado_migrate_closed_workitems $false `
    -ado_production_run $false `
    -gh_pat "ghp_xxx" `
    -gh_org "joshjohanning-org" `
    -gh_repo "migrate-ado-workitems" `
    -gh_update_assigned_to $true `
    -gh_assigned_to_user_suffix "" `
    -gh_add_ado_comments $true
```

## Script Options

| Parameter                       | Required | Default  | Description                                                                                                                                 |
|---------------------------------|----------|----------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `-ado_pat`                      | Yes      |          | Azure DevOps Personal Access Token (PAT) with appropriate permissions to read work items (and update, with `-ado_production_run $true`)     |
| `-ado_org`                      | Yes      |          | Azure DevOps organization to migrate from                                                                                                   |
| `-ado_project`                  | Yes      |          | Azure DevOps project to migrate from                                                                                                        |
| `-ado_area_path`                | Yes      |          | Azure DevOps area path to migrate from - uses the `UNDER` operator                                                                          |
| `-ado_migrate_closed_workitems` | No       | `$false` | Switch to migrate closed/resoled/done/removed work items                                                                                    |
| `-ado_production_run`           | No       | `$false` | Switch to add `copied-to-github` tag and comment on ADO work item                                                                           |
| `-gh_pat`                       | Yes      |          | GitHub Personal Access Token (PAT) with appropriate permissions to read/write issues                                                        |
| `-gh_org`                       | Yes      |          | GitHub organization to migrate work items to                                                                                                |
| `-gh_repo`                      | Yes      |          | GitHub repo to migrate work items to                                                                                                        |
| `-gh_update_assigned_to`        | No       | `$false` | Switch to update the GitHub issue's assignee based on the username portion of an email address (before the @ sign)                          |
| `-gh_assigned_to_user_suffix`   | No       | `""`     | Used in conjunction with `-gh_update_assigned_to`, used to suffix the username, e.g. if using GitHub Enterprise Managed User (EMU) instance |
| `-gh_add_ado_comments`          | No       | `$false` | Switch to add ADO comments as a section with the migrated work item                                                                     |

+ **Note**: With `-gh_update_assigned_to $true`, you/your users will receive a lot of emails from GitHub when the user is assigned to the issue
