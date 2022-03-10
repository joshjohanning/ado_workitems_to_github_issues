# ado_workitems_to_github_issues

##  Notes

Just a heads up, if you have the `-gh_update_assigned_to` flag set to `$true`, you/your users will receive a lot of emails.

### Prerequisites
1. Install az devops and github cli where this is running (ie: action or locally; GitHub-hosted runners already have)
2. Create a label for EACH work item type that is being migrated (as lower case) 
    - ie: "user story", "bug", "task", "feature"
3. Add a tag to eaach work item you want to migrate - ie: "migrate"
    - You can modify the WIQL if you want to use a different way to migrate work items, such as `UNDER [Area Path]`

### Things it migrates
1. Title
2. Description (or for a bug, repro steps and/or system info)
3. State (if the work item is done / closed, it will be closed in GitHub)
4. It will try to assign the work item to the correct user in GitHub - based on ADO email before the `@`
    - This uses the `-gh_update_assigned_to` and `-gh_assigned_to_user_suffix` options
    - Users have to be added to GitHub org
6. Migrate acceptance criteria as part of issue body (if present)
7. Adds in the following as a comment to the issue:
    - Original work item url 
    - Basic details in a collapsed markdown table
    - Entire work item as JSON in a collapsed section

### To Do
1. Create a comment on the Azure DevOps work item that says "Migrated to GitHub Issue #"

### Things it won't ever migrate
1. Created date/update dates

### Example

- [Screenshot](https://user-images.githubusercontent.com/19912012/157728827-88c4d038-a37b-4246-9979-238a8c48f5ca.png)
- [Migrated GitHub Issue](https://github.com/joshjohanning-org/migrate-ado-workitems/issues/291)

## Instructions for Running in Actions

The recommendation is to use a GitHub App to run the migration - a GitHub app has higher rate limits than using a user PAT.

1. Create GitHub App with (can use this [reference](https://josh-ops.com/posts/github-apps/#creating-a-github-app)). Use the following permissions:
    + Repo: `Contents:Read`
    + Repo: `Issues:Read and write`
    + Org: `Members:Read`
1. Create Private Key for GitHub App
1. Obtain App ID and Installation ID - see [the instructions for using smee.io](https://josh-ops.com/posts/github-apps/#creating-a-github-app)
1. Create the following action secrets:
    + `ADO_PAT`: Azure DevOps PAT with appropriate permissions to read work items
    + `PRIVATE_KEY`: The contents of the private key created and downloaded in step #2
1. Use the [action](.github/workflows/migrate-work-items.yml) and update the App ID and Installation ID obtained in step #3
1. Update any defaults in the [action](.github/workflows/migrate-work-items.yml) (ie: Azure DevOps organization and project, GitHub organization and repo)
1. Ensure the action exists in the repo's default branch
1. Run the workflow

## Instructions for Running Locally

Using the GitHub app might be better so you don't reach a limit on your GitHub account on creating new issues 😀

```pwsh
./ado_workitems_to_github_issues.ps1 -ado_pat "xxx" -ado_org "jjohanning0798" -ado_project "PartsUnlimited" -ado_tag "migrate" -gh_pat "ghp_xxx" -gh_org "joshjohanning-org" -gh_repo "migrate-ado-workitems" -gh_update_assigned_to $true -gh_assigned_to_user_suffix "_corp" -gh_add_ado_comments $true
```
