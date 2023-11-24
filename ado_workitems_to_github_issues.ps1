#! /usr/bin/env pwsh

##############################################################
# Migrate Azure DevOps work items to GitHub Issues
##############################################################

# Prerequisites:
# 1. Install az devops and github cli
# 2. [optional]Create a label for EACH work item type that is being migrated (as lower case) 
#      - ie: "user story", "bug", "task", "feature"
#    a. The ADO item type to Github label can be explicit via the config JSON key "azureDevOpsItemTypeToGitHubLabelMap"
#    b. The labels can be automatically created with `-gh_ensure_labels_exist 1` CLI option (currently the default)
# 3. Define under what area path you want to migrate
#      - You can modify the WIQL if you want to use a different way to migrate work items, such as [TAG] = "migrate"

# How to run:
# ./ado_workitems_to_github_issues.ps1 -ado_pat "xxx" -ado_org "jjohanning0798" -ado_project "PartsUnlimited" -ado_area_path "PartsUnlimited\migrate" -ado_migrate_closed_workitems $false -ado_production_run $true -gh_pat "xxx" -gh_org "joshjohanning-org" -gh_repo "migrate-ado-workitems" -gh_update_assigned_to $true -gh_assigned_to_user_suffix "_corp" -gh_add_ado_comments $true

#
# Things it migrates:
# 1. Title
# 2. Description (or repro steps + system info for a bug)
# 3. State (if the work item is done / closed, it will be closed in GitHub)
#    a. The state can also be mapped to a Github V2 Project "Status" column using config JSON key "azureDevOpsStateToGitHubProjectColumnMap", however the columns must exist 
# 4. It will try to assign the work item to the correct user in GitHub - based on ADO email (-gh_update_assigned_to and -gh_assigned_to_user_suffix options) - they of course have to be in GitHub already
#    a. There is also an option to explicitly map users from ADO to GitHub via the config JSON key "azureDevOpsEmailToGitHubAssigneeMap"
# 5. Migrate acceptance criteria as part of issue body (if present)
# 6. Adds in the following as a comment to the issue:
#   a. Original work item url
#   b. Basic details in a collapsed markdown table
#   c. Entire work item as JSON in a collapsed section
#   d. Related items as shield.io badges (and in collapsed markdown table)
#     - Mentions parent issue from child issue for some GitHub linkage
# 7. Milestone (from an Azure DevOps Iteration)
# 8. Adds issue as a card to Github v2 Project (although V2 projects can have workflows themselves to add new issues)
#    a. Note that the Github PAT needs project:write scope (handled automatically via `gh auth login`)
# 9. Labels (from Azure DevOps tags) provided they are mapped in a config JSON under the key "azureDevOpsTagsToGitHubLabelsMap"
# 10. Creates tag "copied-to-github" and a comment on the ADO work item with `-$ado_production_run $true` . The tag prevents duplicate copying.
#

#
# Supports partial migration / resuming previous migration
# 1. Uses a checkpoint file (if specified) to know the ADO URL to GitHub Issue URL mappings it has migrated
# 2. Attempts to use `az devops` and `gh` CLIs to cross reference existing issues based on title and maps to the earliest issue when found
#   - This is only performed for unmapped URLs that are not in the checkpoint - with a warning emitted, use -Debug CLI flag to see details
# 3. Will reattempt to create an issue (every 15 mins, waiting up to 1.5 hours) to workaround GitHub API rate limit throttling 
#

#
# Notes
# 1. Unicode such as emojis are now supported for labels, descriptions, etc as the default encoding is now UTF-8
# 2. A temporary directory is created for errors and posted files and arranged by ADO workitem number to allow manual inspection of content after the fact, e.g. AB1.temp_issue_body.txt etc.
#

#
# Things it won't ever migrate:
# 1. Created date/update dates
#

[CmdletBinding()]
param (
    [string]$ado_pat, # Azure DevOps PAT
    [string]$ado_org, # Azure devops org without the URL, eg: "MyAzureDevOpsOrg"
    [string]$ado_project, # Team project name that contains the work items, eg: "TailWindTraders"
    [string]$ado_area_path, # Area path in Azure DevOps to migrate; uses the 'UNDER' operator)
    [bool] $ado_migrate_closed_workitems = $false, # migrate work items with the state of done, closed, resolved, and removed
    [bool]$ado_production_run = $false, # tag migrated work items with 'migrated-to-github' and add discussion comment
    [string]$gh_pat, # GitHub PAT
    [string]$gh_org, # GitHub organization to create the issues in
    [string]$gh_repo, # GitHub repository to create the issues in
    [string]$gh_project_name = $null, # GitHub V2 project to associate issues with
    [bool]$gh_update_assigned_to = $false, # try to update the assigned to field in GitHub
    [string]$gh_assigned_to_user_suffix = "", # the emu suffix, ie: "_corp"
    [bool]$gh_add_ado_comments = $false, # try to get ado comments
    [string]$gh_milestone_iteration_name_prefix = "", # milestone name prefix when importanting iteration names from Azure DevOps
    [bool]$gh_ensure_labels_exist = $true, # ensure that the labels exist in the GitHub repo
    [string[]]$gh_labels = @("ado-export 📤"), # define an array of label strings to be added to the issue
    [string]$ado_to_gh_workitem_checkpoint_file = $null, # path to a JSON file to write the ADO work item ID and GitHub issue URL to
    [bool]$sync_ado_iterations_to_gh_milestones = $true, # sync Azure DevOps iterations to GitHub milestones
    [bool]$gh_mention_related_items = $false, # mention related items in the issue body, use with caution as these cannot be removed once added
    [bool]$gh_update_existing_issues = $true, # update existing issues with new information
    [string]$gh_archive_closed_items_label = "archive 🗃️", # marked closed items as archived the provided label, empty avoids adding a label
    [bool]$gh_deduplicate_existing_issues = $true, # deduplicate existing issues based on title. WARNING: potentially dangerous as it will take the latest issue when deduplicating
    [bool]$gh_wait_for_rate_limit_reset = $true, # wait for the GitHub API rate limit to reset before continuing, useful for large migrations but slow as it waits for 1 hour to allow the rate limit to reset
    [string]$config_file = $null, # path to a JSON file to load configuration from, see MigrationConfig::ImportConfig for fields supported
    [int32]$ado_start_workitem_id = 0 # the Azure DevOps work item ID to start from, useful for resuming a migration
)

# set default encoding to UTF8 to be compatible with unicode characters returned from the GitHub API
$PSDefaultParameterValues = @{ "*:Encoding" = "utf8" }
[Console]::OutputEncoding = [Console]::InputEncoding = $OutputEncoding = [System.Text.Encoding]::UTF8

$script:TEMPORARY_DIRECTORY = New-TemporaryFile | ForEach-Object {
    Remove-Item $_ -Force; (New-Item -ItemType Directory -Path $_).FullName
}
Write-Debug "Temporary directory: $TEMPORARY_DIRECTORY"

# save map to json
function Save-MapToJSON() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path,
        [Parameter(Mandatory = $true)]
        [hashtable]$map
    )
    if ($path) {
        $json = $map | ConvertTo-Json
        $json | Out-File -FilePath $path -Encoding utf8
        Write-Debug "Map saved to '$path'"
    }
}

# load map from json
function Import-MapFromJSON() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$path,
        [bool]$backup = $true,
        [string]$encoding = "utf8"
    )
    # load a map from json if path exists, otherwise gracefully return an empty map
    $map = @{}
    if ($path -and (Test-Path -Path $path)) {
        # construct backup path based on date
        if ($backup) {
            $backupPath = $path -replace "\.json$", ("_" + (Get-Date -Format "yyyyMMddHHmmss") + ".json")
            Copy-Item -Path $path -Destination $backupPath
        }
        $json = Get-Content -Path $path -Raw -Encoding $encoding
        try {
            $obj = $json | ConvertFrom-Json
            $obj.PSObject.Properties | ForEach-Object {
                $map[$_.Name] = $_.Value
            }
        }
        catch {
            Write-Warning "Failed to load map from json file '$path' - using empty map..."
        }
    }
    else {
        throw "A valid path is required"
    }
    return $map
}

function ConvertTo-OrderedDictionary() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$obj
    )
    $map = @{}
    $obj.PSObject.Properties | ForEach-Object {
        $map[$_.Name] = $_.Value
    }
    return $map
}


class GithubProject {
    [Int32]$number
    [System.Uri]$url
    [string]$shortDescription
    [bool]$public
    [bool]$closed
    [string]$title
    [string]$id
    [PSCustomObject]$items
    [PSCustomObject]$fields
    [PSCustomObject]$owner
    [string]$readme

    GithubProject($projectName, $githubOrg) {
        $proj = Get-GithubProjectFromName -projectName $projectName -githubOrg $githubOrg
        if (!$proj) {
            $proj = gh project create --title="$projectName" --owner=$githubOrg --format=json | ConvertFrom-JSON
        }

        if (!$proj) {
            throw "No GitHub project named '${projectName}'."
        }

        foreach ($field in $proj.PSObject.Properties) {
            $this."$($field.Name)" = $field.Value
        }
    }
}


class MigrationState {
    [PSCustomObject[]]$azureDevOpsItemsQuery = @()
    [hashtable]$azureDevOpsWorkItemUrlToGitHubIssueUrlMap = @{}
    [hashtable]$githubPullRequestInfo = @{}
    [GithubRepository]$githubRepositoryInfo = (Get-GitHubRepoInfo -org $gh_org -repo $gh_repo)
    [hashtable]$history = @{}
    [GithubProject]$githubProject = [GithubProject]::new($gh_project_name, $gh_org)

    [string]$PULL_REQUEST_JSON_FIELDS = "number,url,title,state,mergeable,milestone,reviews,author,assignees,body,comments,commits,changedFiles,baseRefName,headRepository,projectCards,projectItems,labels,createdAt,updatedAt"

    [hashtable] GetGitHubPullRequestInfo([bool]$all = $true) {
        $additionalFlags = "--limit 10000"
        if ($all) {
            additionalFlags += " --search='state:open -or state:closed -or state:merged'"
        }
        $pullRequestInfo = gh pr list $additionalFlags --json="$($this.PULL_REQUEST_JSON_FIELDS)" | ConvertFrom-JSON
        $map = @{}
        if ($pullRequestInfo) {
            $pullRequestInfo.PSObject.Properties | ForEach-Object {
                $map[$_.Value.url] = $this.githubPullRequestInfo[$_.Value.url] = $_.Value
            }
        }
        return $map
    }

    [string] GetGitHubPullRequestState([string]$url) {
        # check the GitHub repository information first before falling back to viewing the pr directly through the API
        if (!$this.githubPullRequestInfo) {
            $this.githubPullRequestInfo = $this.GetGitHubPullRequestInfo($true)
        }
        $state = $this.githubPullRequestInfo[$url] | Select-Object -ExpandProperty state
        if (!$state) {
            $pr = gh pr view $url --json "$this.PULL_REQUEST_JSON_FIELDS" | ConvertFrom-JSON
            $this.githubPullRequestInfo[$url] = $pr  # update map
            $state = $pr.state
        }
        return $state
    }

    [PSCustomObject[]] GetAzureDevOpsItems(
        $azureDevOpsAreaPath = $ado_area_path, `
            [int32]$startWorkItemId = 0, `
            [bool]$onlyClosedItems = $ado_migrate_closed_workitems
    ) {
        # get a list of board work items to migrate from Azure DevOps, but chunk in 1000 item batches
        # add the wiql to not migrate closed work items
        if ($onlyClosedItems -eq "1") {
            $closedSubquery = "[State] <> 'Done' and [State] <> 'Closed' and [State] <> 'Resolved' and [State] <> 'Removed' and"
        }
        else {
            $closedSubquery = "[State] != 'N/A' and"
        }
        $cursorId = $startWorkItemId - 0
        $query = @()
        while ($true) {
            $wiql = "select [ID], [Title], [System.Tags] from workitems where [ID] > $cursorId "
            $wiql += "and $closedSubquery [System.AreaPath] UNDER '$azureDevOpsAreaPath' "
            $wiql += "and not [System.Tags] Contains 'copied-to-github' order by [ID] ASC";

            $queryChunk = az boards query --wiql $wiql | ConvertFrom-Json
            if (!$cursorId) {
                $query = $queryChunk
            }
            else {
                $query += $queryChunk
            }

            if ($queryChunk.Count -lt 1000) {
                break
            }
            $cursorId = ($query | Measure-Object -Property id -Maximum).Maximum
        }
        $this.azureDevOpsItemsQuery = $query
        return $query
    }

    static [MigrationState] ImportState([string]$path) {
        [MigrationState]$state = [MigrationState]::new()
        try {
            $state.azureDevOpsWorkItemUrlToGitHubIssueUrlMap = Import-MapFromJSON -path "$path"
        }
        catch {
            Write-Warning "Failed to load state from json file '$path' - using empty state..."
        }
        return $state
    }
}

class MigrationConfig {
    [hashtable]$azureDevOpsItemTypeToGitHubLabelMap = @{}
    [hashtable]$azureDevOpsItemStateToGitHubLabelMap = @{}
    [hashtable]$azureDevOpsStateToGitHubProjectColumnMap = @{}
    [hashtable]$azureDevOpsEmailToGitHubAssigneeMap = @{}
    [hashtable]$azureDevOpsTagsToGitHubLabelsMap = @{}
    [hashtable]$vsftsRepoInternalIdMap = @{}

    [void]UpdateItemStateToLabelMap([bool]$overwrite = $false) {
        # dynamically create the map of ADO states to GitHub labels
        foreach ($item in $this.azureDevOpsStateToGitHubProjectColumnMap.GetEnumerator()) {
            if ($overwrite -or !$this.azureDevOpsItemStateToGitHubLabelMap[$item.Key]) {
                $this.azureDevOpsItemStateToGitHubLabelMap[$item.Key] = $item.Value
            }
        }
    }

    static [MigrationConfig]ImportConfig([string]$path = "$config_file") {
        $config = [MigrationConfig]::new()
        try {
            $jsonConfig = Import-MapFromJSON -path $path -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to load config from json file '$path' - using empty config..."
            $jsonConfig = @{}
        }
        $fields = @(
            "azureDevOpsItemTypeToGitHubLabelMap",
            "azureDevOpsItemStateToGitHubLabelMap",
            "azureDevOpsStateToGitHubProjectColumnMap",
            "azureDevOpsEmailToGitHubAssigneeMap",
            "azureDevOpsTagsToGitHubLabelsMap",
            "vsftsRepoInternalIdMap"
        )
        foreach ($field in $fields) {
            # Do not clobber existing config data if the imported data is empty for a given field
            if (!$jsonConfig[$field]) {
                Write-Warning "Config field '$field' is empty"
                $jsonConfig[$field] = @{}
            }
            else {
                $config."$field" = ConvertTo-OrderedDictionary -obj $jsonConfig[$field]
            }
        }
        $config.UpdateItemStateToLabelMap($false)
        return $config
    }
}

# Load the migration state if provided
$script:state = [MigrationState]::ImportState("$ado_to_gh_workitem_checkpoint_file")

# Load the config file if provided
${script:config} = [MigrationConfig]::ImportConfig("$config_file")

# generate a function which takes a hashtable of user email addresses to user displayNames from Azure DevOps and attempts to map them to GitHub usernames
# This is tricky as GitHub usernames are not related to email addresses, so attempt a fuzzy match based on displayName
function Get-MapAzureDevOpsEmailToGitHubAssigneeMap() {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$azureDevOpsUsersMap
    )
    $azureDevOpsEmailToGitHubAssigneeMap = @{}
    foreach ($email in $azureDevOpsUsersMap.Keys) {
        $displayName = $azureDevOpsUsersMap[$email]
        $githubUsername = ${script:config}.azureDevOpsEmailToGitHubAssigneeMap[$email]
        if ($githubUsername) {
            $azureDevOpsEmailToGitHubAssigneeMap[$email] = $githubUsername
        }
        else {
            $githubUsername = $displayName -replace " ", "-"
            $githubUsername = $githubUsername -replace "[^a-zA-Z0-9-]", ""
            $githubUsername = $githubUsername.ToLower()
            $azureDevOpsEmailToGitHubAssigneeMap[$email] = $githubUsername
        }
    }
    return $azureDevOpsEmailToGitHubAssigneeMap
}

# Set the auth token for az commands
$env:AZURE_DEVOPS_EXT_PAT = $ado_pat;
# Set the auth token for gh commands
$env:GH_TOKEN = $gh_pat;

az devops configure --defaults organization="https://dev.azure.com/$ado_org" project="$ado_project"

# check that extensions are installed and install them if not
$installedGitHubExtensions = gh extensions list
foreach ($extension in @("github/gh-projects", "valeriobelli/gh-milestone")) {
    if ($installedGitHubExtensions | Where-Object { $_ -notmatch $extension }) {
        gh extensions install $extension
    }
}

function Convert-AzureDevOpsLinkUrl() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$url, # the Azure DevOps URL link to resolve
        [bool]$useMappedUrl = $false  # use the mapped issue URL rather than the original URL
    )

    $github_url = ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$url]
    if ($useMappedUrl -and $github_url) {
        return $github_url  # used the mapped issue URL rather than the original URL
    }

    # check whether the URL is an internal API Azure DevOps URL and resolve it to a public URL
    if ($url -match "https://dev.azure.com/" -and $url -match "/_apis/wit/workItems/") {
        $url_encoded_ado_org = $ado_org -replace " ", "%20" -replace "#", "%23"
        $url_encoded_ado_project = $ado_project -replace " ", "%20" -replace "#", "%23"
        $item = Get-ItemNumberFromUrl -url $url
        $devops_url = "https://dev.azure.com/$url_encoded_ado_org/$url_encoded_ado_project/_workitems/edit/$item"
        return $devops_url
    }

    # check whether the URL is a valid VSTS URL by checking for "vstfs://" scheme
    if ($url -notmatch "^vstfs:///GitHub") {
        return $url  # do not resolve non-VSTS URLs
    }

    # Step 1: Extract repository ID and commit hash from VSTS URL
    $split_url = $url -split "/"
    $repo_internal_id, $github_id = $split_url[-1] -split "%2f"

    $github_link_type = $url -replace "vstfs:///GitHub/", "" -split "/" | Select-Object -First 1
    $github_link_type = $github_link_type -replace "PullRequest", "PR"
    $github_url = $null

    $repo_name = ${script:config}.vsftsRepoInternalIdMap[$repo_internal_id]
    if ($null -eq $repo_name) {
        Write-Warning "Could not find repository name for repository internal ID $repo_internal_id"
        return $github_url
    }

    if ($github_link_type -eq "Commit") {
        $github_url = "https://github.com/$gh_org/$repo_name/commit/$github_id"
    }
    elseif ($github_link_type -eq "PR") {
        $github_url = "https://github.com/$gh_org/$repo_name/pull/$github_id"
    }
    elseif ($github_link_type -eq "Issue") {
        $github_url = "https://github.com/$gh_org/$repo_name/issues/$github_id"
    }
    else {
        Write-Warning "Unknown GitHub link type $github_link_type"
    }

    return $github_url
}

function Get-AzureDevOpsUsers() {
    $map = @{}
    az devops user list --detect --query items | ConvertFrom-JSON | ForEach-Object {
        $map[$_.user.principalName] = $_.user.displayName
    }
    return $map
}


$script:GITHUB_REPO_JSON_FIELDS = "name,owner,description,homepageUrl,hasIssuesEnabled,hasWikiEnabled,hasProjectsEnabled,licenseInfo,visibility,createdAt,updatedAt,primaryLanguage,openGraphImageUrl,labels,milestones"

function Get-GitHubRepoInfo() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$org,
        [Parameter(Mandatory = $true)]
        [string]$repo
    )
    $repoInfo = gh repo view $org/$repo --json="${script:GITHUB_REPO_JSON_FIELDS}" | ConvertFrom-JSON
    return $repoInfo

}

enum GithubRepoVisibility {
    PUBLIC
    PRIVATE
}

class GithubRepoOwner {
    [string]$login
    [string]$id

    [string]ToString() {
        return $this.login
    }
}

class GithubLabel {
    [string]$id
    [string]$name
    [string]$color
    [string]$description

    [string]ToString() {
        return $this.name
    }
}

class GithubMilestone {
    [int32]$number
    [string]$title
    [string]$description
    [System.DateTime]$dueOn

    [string]ToString() {
        return $this.title
    }
}



class GithubRepository {
    [string]$name
    [GithubRepoOwner]$owner
    [string]$description
    [System.Uri]$homepageUrl
    [bool]$hasIssuesEnabled
    [bool]$hasWikiEnabled
    [bool]$hasProjectsEnabled
    [string]$licenseInfo
    [GithubRepoVisibility]$visibility
    [System.DateTime]$createdAt
    [System.DateTime]$updatedAt
    [PSCustomObject]$primaryLanguage
    [System.Uri]$openGraphImageUrl
    [GithubLabel[]]$labels
    [GithubMilestone[]]$milestones

    GitHubRepository([object]$obj) {
        $obj.PSObject.Properties | ForEach-Object {
            $this."$($_.Name)" = $_.Value
        }
    }

    GithubRepository([string]$org, [string]$repo) {
        $repoInfo = Get-GitHubRepoInfo -org $org -repo $repo
        foreach ($field in $repoInfo.PSObject.Properties) {
            $this."$($field.Name)" = $field.Value
        }
    }

}


function Get-AzureDevOpsLinkShield() {
    param(
        [Parameter(Mandatory = $true)]
        [string]$url,
        [string]$relationName
    )
    $resolvedUrl = Convert-AzureDevOpsLinkUrl -url $url

    $label = Get-ItemNumberFromUrl -url $resolvedUrl
    if ($label.Length -gt 7) {
        $label = $label.Substring(0, 7)  # shorten commit hash
    }

    $icon = "github"
    $color = "whitesmoke"
    if ($relationName -eq "GitHub Issue") {
        $type = "issue"
    }
    elseif ($relationName -eq "GitHub Pull Request") {
        $type = "pr"
    }
    elseif ($relationName -eq "GitHub Commit") {
        $type = "commit"
    }
    else {
        $type = $relationName.ToLower() -replace " ", "--"
        $icon = "azure-devops"
        $color = "0078D7"
        $label = "AB%23$label"
    }
    $shield = "[![$type](https://img.shields.io/badge/${type}-${label}-${color}?logo=$icon)]($resolvedUrl)"
    return $shield
}

function Get-GithubOAuthTokenScopesArray() {
    $scopes = @(curl.exe -sS -f -I -H "Authorization: token $(gh auth token)" `
            "https://api.github.com/user" | Select-String -Pattern "^X-OAuth-Scopes: (.*)$" `
        | ForEach-Object { $_.Matches.Groups[1].Value.Split(",") } `
        | ForEach-Object { $_.Trim() })
    return $scopes
}

function Test-HasGithubOAuthTokenScope() {
    param(
        [string]$scope # the scope to test for, e.g. "repo", "workflow", etc.
    )
    $items = Get-GithubOAuthTokenScopesArray
    $items.Contains($scope)
}

function Get-CachedGitHubRepositoryMilestones() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$githubOrg, # the name of the github org to get the milestones for, e.g. "MyOrg"
        [Parameter(Mandatory = $true)][string]$githubRepo # the name of the github repo to get the milestones for, e.g. "MyRepo"
    )
    if (!${script:state}.githubRepositoryInfo) {
        ${script:state}.githubRepositoryInfo = Get-GitHubRepoInfo -org $githubOrg -repo $githubRepo
    }
    $repoMilestones = @{}
    ${script:state}.githubRepositoryInfo.milestones | ForEach-Object { $repoMilestones[$_.title] = $_ }
    return $repoMilestones
}

function Get-GithubProjectFromName() {
    param(
        [string]$projectName, # the name of the project to get the number for, e.g. "My Project"
        [string]$githubOrg  # the name of the github org to get the project number for, e.g. "MyOrg"
    )
    $projects = (gh projects list --org $githubOrg --format json | ConvertFrom-Json).projects
    $project = $projects | Where-Object { $_.title -eq "$projectName" }
    return $project
}

function Get-AzureDevopsTagArray() {
    $auth_header = "Basic $([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$ado_pat")))"
    $url = "https://dev.azure.com/$ado_org/$ado_project/_apis/wit/tags?api-version=7.1-preview.1"
    $headers = @{
        "Authorization" = $auth_header
    }
    $response = Invoke-RestMethod -Uri $url -Headers $headers 2>$null
    return $response.value | ForEach-Object { $_.name }
}

$script:ISSUE_JSON_FIELDS = "assignees,author,body,closed,closedAt,comments,createdAt,id,labels,milestone,number,projectCards,projectItems,reactionGroups,state,title,updatedAt,url"

function Get-ExistingIssuesInformationMap() {
    [CmdletBinding()]
    param(
        [int32]$limit = 5000
    )
    $map = @{}
    if ($limit -gt 100) {
        Write-Warning "Refreshing up to $limit issues from GitHub (this may take a long time)..."
    }
    $items = gh issue list --limit $limit --state=all --json "$script:ISSUE_JSON_FIELDS" --jq 'reduce .[] as $item ({}; .[$item.url] = $item)' | ConvertFrom-JSON
    $items.PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value }
    Write-Debug "Found $($map.Count) existing issues"
    return $map
}


$script:existingGitHubIssuesInformationTable = Get-ExistingIssuesInformationMap

function Get-ExistingIssuesToTitleMap() {
    $map = @{}
    foreach ($issue in $script:existingGitHubIssuesInformationTable.Values) {
        $map[$issue.url] = $issue.title
    }
    return $map
}

function Get-ExistingDevOpsUrlsToGitHubIssueUrlsMap() {
    param(
        [PSCustomObject[]]$azureDevOpsItemsQuery,
        [string]$take = "first" # "first", "last" or $null
    )
    $issueToTitleMap = Get-ExistingIssuesToTitleMap
    $titleToIssueMap = @{}
    foreach ($item in $issueToTitleMap.GetEnumerator()) {
        $titleToIssueMap[$item.Value] = $item.Key
    }
    if ($titleToIssueMap.Count -lt $issueToTitleMap.Count) {
        Write-Warning "Duplicate issue titles found - deduplication will may not work correctly"
        # count duplicate titles and list issue url for each
        $duplicateTitles = @{}
        foreach ($item in $issueToTitleMap.GetEnumerator()) {
            $duplicateTitles[$item.Value] = @()
        }
        foreach ($item in $issueToTitleMap.GetEnumerator()) {
            $duplicateTitles[$item.Value] += $($item.Key)
        }
        foreach ($item in $duplicateTitles.GetEnumerator()) {
            if ($item.Value.Count -gt 1) {
                Write-Host "`nDuplicate issue title '$($item.Key)' found for $($item.Value.Count) issues:" -ForegroundColor Blue
                $_duplicatesMap = @{}
                foreach ($issueUrl in $item.Value) {
                    $_duplicatesMap[[int]$issueUrl.Split("/")[-1]] = $issueUrl
                }
                $_item = 0
                foreach ($key in $_duplicatesMap.Keys | Sort-Object $(if ($take -eq "last") { "-Descending" })) {
                    $issue = $_duplicatesMap[$key]
                    if ($_item -eq 0 -and $take) {
                        $titleToIssueMap[$item.Key] = $issue
                    }
                    if ($titleToIssueMap[$item.Key] -eq $issue) {
                        Write-Host "  - $issue * (selected)" -ForegroundColor Blue
                    }
                    else {
                        Write-Host "  - $issue" -ForegroundColor Blue
                    }
                    $_item++
                }
            }
        }
    }
    $azureDevOpsItemUrlToGitHubIssueUrlMap = @{}
    foreach ($item in ${script:state}.azureDevOpsItemsQuery) {
        $title = $item.fields.'System.Title'
        $issueUrl = $titleToIssueMap[$title]
        if ($issueUrl) {
            $azureDevOpsItemUrlToGitHubIssueUrlMap[$item.url] = $issueUrl
        }
    }
    return $azureDevOpsItemUrlToGitHubIssueUrlMap
}

function Update-GitHubComment {
    param(
        [Parameter(Mandatory=$true)]
        [string]$commentId,
        [Parameter(Mandatory=$true)]
        [string]$newComment
    )

    $escapedComment = $newComment.Replace('\', '\\').Replace('"', '\"').replace("`n", "\n").replace("`r", "")
    $jsonPayload = "{ `"body`": `"$escapedComment`" }"

    $headers = @{
        "Authorization" = "token $gh_pat"
        "Content-Type" = "application/json"
    }

    $url = "https://api.github.com/repos/$gh_org/$gh_repo/issues/comments/$commentId"

    try {
        Invoke-RestMethod -Uri $url -Method Patch -Body $jsonPayload -Headers $headers
    }
    catch {
        Write-Output "Failed to update comment ${commentId}: $_"
    }
}


$query = ${script:state}.GetAzureDevOpsItems($ado_area_path, $ado_start_workitem_id, $ado_migrate_closed_workitems)
Write-Output "⚙️  Migration query identified $($query.Count) work items to migrate"

Write-Output "🔍 Checking for existing GitHub issues..."
$azureDevOpsItemUrlToGitHubIssueUrlMap = Get-ExistingDevOpsUrlsToGitHubIssueUrlsMap -azureDevOpsItemsQuery $query
Write-Warning "$($azureDevOpsItemUrlToGitHubIssueUrlMap.Count) existing GitHub issues found based on title matching"

# attempt to deduplicate existing issues based on title, updating the migration items map when no existing issue is found
if ($gh_deduplicate_existing_issues -and $azureDevOpsItemUrlToGitHubIssueUrlMap.Count -gt 0) {
    # only get the detailsId once to avoid negatively impacting performance
    $_azureBoardId = (az boards work-item show --id $query[0].id --output json | ConvertFrom-Json).url.Split("/")[4]
    foreach ($item in $azureDevOpsItemUrlToGitHubIssueUrlMap.GetEnumerator()) {
        # update azureDevOpsWorkItemUrlToGitHubIssueUrlMap with existing issues
        if (-not ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$item.Key]) {
            ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$item.Key] = $item.Value
        }

        # attempt to create a details alias of the prior work item assuming $_azureBoardId does not change
        $_detailsKey = $item.Key -replace "_apis", "$_azureBoardId/_apis"
        if (-not ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$_detailsKey]) {
            ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$_detailsKey] = $item.Value
        }
    }
}

$count = 0;

if (!$(Test-HasGithubOAuthTokenScope -scope "project")) {
    $ghAuthArgs = ""
    if ($null -ne $env:GH_AUTH_PROTOCOL) {
        $ghAuthArgs += "--auth-protocol $env:GH_AUTH_PROTOCOL "
    }
    gh auth login --scopes read:org --scopes repo --scopes workflow --scopes project $ghAuthArgs
}

${script:state}.githubProject = [GithubProject]::new($gh_project_name, $gh_org)

# ensure that the labels exist in the GitHub repo

$extraLabelArgs = ""
ForEach ($gh_label in $gh_labels) {
    $extraLabelArgs += "--label `"$gh_label`" "
}


function Confirm-GitHubLabelsExist() {
    $repoLabels = @{}
    if (!${script:state}.githubRepositoryInfo.labels) {
        ${script:state}.githubRepositoryInfo = Get-GitHubRepoInfo -org $gh_org -repo $gh_repo
    }
    ${script:state}.githubRepositoryInfo.labels | ForEach-Object { $repoLabels[$_.name] = $_ }
    ForEach ($label in $gh_labels | Where-Object { $_ -notin $repoLabels.Keys }) {
        Write-Output "Ensuring GitHub label exists: $label"
        label create "$label" --color "#ffffff" > $null 2>&1
    }
    ForEach ($each in ${script:config}.azureDevOpsItemTypeToGitHubLabelMap.GetEnumerator()) {
        if ($each.Value -and $each.Value -notin $repoLabels.Keys) {
            Write-Output "Ensuring Azure DevOps item type GitHub label exists: '$($each.Key)' -> '$($each.Value)'"
            gh label create "$($each.Value)" --color "#ffffff" > $null 2>&1
        }
    }
    ForEach ($each in ${script:config}.azureDevOpsItemStateToGitHubLabelMap.GetEnumerator()) {
        if ($each.Value -and $each.Value -notin $repoLabels.Keys) {
            Write-Output "Ensuring Azure DevOps state GitHub label exists: '$($each.Key)' -> '$($each.Value)'"
            gh label create "$($each.Value)" --color "#ffffff" > $null 2>&1
        }
    }
    ForEach ($each in ${script:config}.azureDevOpsTagsToGitHubLabelsMap.GetEnumerator()) {
        if ($each.Value -and $each.Value -notin $repoLabels.Keys) {
            Write-Output "Ensuring Azure DevOps tag GitHub label exists: '$($each.Key)' -> '$($each.Value)'"
            gh label create "$($each.Value)" --color "#0063aa" > $null 2>&1
        }
    }
}

Write-Debug "Milestones found for project '$gh_project_name': $(${script:state}.githubRepositoryInfo.milestones -join '; ')"


function Confirm-GitHubMilestonesExist() {
    param(
        [string]$githubOrg, # the name of the github org to get the milestones for, e.g. "MyOrg"
        [string]$githubRepo # the name of the github repo to get the milestones for, e.g. "MyRepo"s
    )
    $repoMilestones = Get-CachedGitHubRepositoryMilestones -githubOrg $githubOrg -githubRepo $githubRepo
    Write-Output "Refreshing GitHub milestones from Azure DevOps iterations..."
    $adoIterations = $(az boards iteration project list | ConvertFrom-Json).children
    [GithubMilestone[]]$githubMilestones = @()
    ForEach ($adoIteration in $adoIterations) {
        $milestoneIterationName = "$gh_milestone_iteration_name_prefix$($adoIteration.name)"
        $githubMilestone = $repoMilestones.Keys | Where-Object { $_ -eq "$milestoneIterationName" }
        if (!$githubMilestone -and $githubMilestone -notin $repoMilestones.Keys) {
            # create the milestone
            # NOTE: closed milestones are not recognized by the API, but are by the UI
            $state = "open"  # TODO: Decide whether to do anything fancier here
            # get the due date from the iteration and convert to ISO format
            $dueOn = $adoIteration.attributes.finishDate.ToString("o")
            $startedOn = $adoIteration.attributes.startDate.ToString("o")
            $description = "Azure DevOps Iteration $($adoIteration.path), started on $startedOn"
            $milestone = gh api -H "Accept: application/vnd.github.v3+json" `
                /repos/$gh_org/$gh_repo/milestones `
                -F title="$milestoneIterationName" `
                -F state="$state" `
                -F description="$description" `
                -f due_on="$dueOn" 2>$null | ConvertFrom-Json
            if ($milestone -and -not $milestone -match "already_exists") {
                Write-Output "Milestone '$milestoneIterationName' created: $($milestone.url)"
            }
            $githubMilestones += [GithubMilestone]@{
                number = $milestone.number
                title = $milestone.title
                description = $milestone.description
                dueOn = $milestone.due_on
            }
        }
        else {
            Write-Debug "Milestone already exists: $milestoneIterationName"
        }
    }
    ${script:state}.githubRepositoryInfo.milestones = (
        [GithubMilestone[]](
            ${script:state}.githubRepositoryInfo.milestones + $githubMilestones | Sort-Object -Unique
        )
    )
}

if ($sync_ado_iterations_to_gh_milestones) {
    Confirm-GitHubMilestonesExist -githubOrg $gh_org -githubRepo $gh_repo
}

if ($gh_ensure_labels_exist) {
    Confirm-GitHubLabelsExist
}

$gh_board_status_field_id = (
    gh project field-list ${script:state}.githubProject.number --owner=$gh_org --format=json | ConvertFrom-JSON
).fields | Where-Object { $_.name -eq "Status" } | Select-Object -ExpandProperty id

function New-ProjectBoardItem() {
    # create a new board item for project number from issue number and assign it to column
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        # mandatory parameters
        [Parameter(Mandatory = $true)][GithubProject]$project, # the project object to create the board item for, e.g. `@{"id": "PVT_abc123", "number": 1}`
        [Parameter(Mandatory = $true)][string]$issueUrl, # the url of the issue to create the board item for
        [string]$projectBoardStatus = $null  # the status of the board item to create, e.g. "closed"
    )
    $boardItem = gh projects item-add $project.number --url $issueUrl --org $project.owner.login --format json | ConvertFrom-JSON
    if ($projectBoardStatus -and $gh_board_status_field_id -and $boardItem) {
        Set-GitHubProjectStatusFieldValue -status $projectBoardStatus -projectId $project.id -boardItemId $boardItem.id
    }
}

$script:GitHubProjectNodeArray = @()

function Get-GitHubProjectNodeArray() {
    if (!$script:GitHubProjectNodeArray) {
        $result = gh api graphql -f query="
        query{
            node(id: `"$(${script:state}.githubProject.id)`") {
                ... on ProjectV2 {
                    fields(first: 20) {
                        nodes {
                        ... on ProjectV2SingleSelectField {
                                id
                                name
                                options {
                                    id
                                    name
                                }
                            }
                        }
                    }
                }
            }
        }" | ConvertFrom-JSON
        $fields = $result.data.node.fields.nodes
        $script:GitHubProjectNodeArray = $fields
    }
    else {
        $fields = $script:GitHubProjectNodeArray
    }
    return $fields
}

function Get-GithubIssue() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$issueUrl  # the url of the issue to check
    )
    $issue = $script:existingGitHubIssuesInformationTable[$issueUrl]
    if ($issueUrl -and !$issue) {
        $issue = gh issue view $issueUrl --json="$script:ISSUE_JSON_FIELDS" | ConvertFrom-JSON
        $script:existingGitHubIssuesInformationTable[$issueUrl] = $issue
    }
    return $issue
}

function Get-IsGithubIssueAssignedTo() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$assignee, # the assignee to check for
        [Parameter(Mandatory = $true)][string]$issueUrl  # the url of the issue to check
    )
    $issue = Get-GithubIssue -issueUrl $issueUrl
    return $issue.assignees | Where-Object { $_.login -eq $assignee }
}

function Get-GithubIssueState() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$issueUrl  # the url of the issue to check
    )
    $issue = $(Get-GithubIssue -issueUrl $issueUrl)
    return $issue.state
}

function Get-HasGithubIssueMilestone() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$milestone, # the milestone to check for
        [Parameter(Mandatory = $true)][string]$issueUrl  # the url of the issue to check
    )
    return [bool]$script:existingGitHubIssuesInformationTable[$issueUrl].milestone.title -eq $milestone
}

function Get-HasGitHubRepositoryLabel() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$label, # the milestone to check for
        [bool]$fuzzy = $true  # whether to use fuzzy matching
    )

    if (!${script:state}.githubRepositoryInfo) {
        ${script:state}.githubRepositoryInfo = Get-GitHubRepoInfo -org $gh_org -repo $gh_repo
    }
    $labels = ${script:state}.githubRepositoryInfo.labels
    if (-not $labels) {
        $result = $false
    }
    elseif ($fuzzy) {
        $result = $labels | Where-Object { $_.name.Split(" ")[0] -eq "$label".Split(" ")[0] }
    }
    else {
        $result = $labels | Where-Object { $_.name -eq "$label" }
    }
    return [bool]$result
}

function Get-HasGitHubIssueLabel() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$label, # the milestone to check for
        [Parameter(Mandatory = $true)][string]$issueUrl, # the url of the issue to check
        [bool]$fuzzy = $true  # whether to use fuzzy matching
    )
    $labels = $script:existingGitHubIssuesInformationTable[$issueUrl] | Select-Object -ExpandProperty "labels"
    if (!$labels -or !$label) {
        $result = $false
    }
    elseif ($fuzzy) {
        $result = $labels | Where-Object { $_.name -eq $label -or $_.name.Split(" ")[0] -eq "$label".Split(" ")[0] }
    }
    else {
        $result = $labels | Where-Object { $_.name -eq "$label" }
    }
    return [bool]$result
}

function Get-GitHubProjectStatusOptionMap() {
    param(
        # use nodes object
        [PSCustomObject[]]$node
    )

    $optionMap = @{}
    ForEach ($option in $node.options) {
        $optionMap[$option.name] = $option.id
    }
    return $optionMap
}

function Set-GitHubProjectStatusFieldValue() {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$projectId, # the project id to set the board item status for, e.g. "PVT_abc123"
        [Parameter(Mandatory = $true)]
        [string]$boardItemId, # the board item id to set the status for, e.g. "MDEzOlByb2plY3RWaWV3MjI2MjQ5NjQ="
        [Parameter(Mandatory = $true)]
        [string]$status  # the status to set the project board item to, e.g. "closed"
    )
    $nodes = Get-GitHubProjectNodeArray
    $node = $nodes | Where-Object { $_.name -eq "Status" }
    $optionMap = Get-GitHubProjectStatusOptionMap -node $node
    if ($optionMap.ContainsKey($board_status_string)) {
        $result = gh api graphql -f query="
        mutation {
            updateProjectV2ItemFieldValue(
                input: {
                    projectId: `"$($projectId)`"
                    itemId: `"$($boardItemId)`"
                    fieldId: `"$($node.id)`"
                    value: {
                        singleSelectOptionId: `"$($optionMap[$status])`"
                    }
                }
            ) {
                projectV2Item {
                    id
                }
            }
        }"
        if ($result) {
            $result = $result | ConvertFrom-JSON 2>$null
            Write-Output "  ↳ Board item status updated to '$status'"
        }
        else {
            Write-Host "    ↳ Failed to update board item status to '$status'" -ForegroundColor Red
        }
    }
    else {
        Write-Warning "Status '$status' not found in project board item status field options"
    }
}


function Get-GitHubIssueAzureDevOpsDescription() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$details, # the details of the work item to get the description for
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$relations  # the relations of the work item to get the description for
    )

    $description = ""

    # bug doesn't have Description field - add repro steps and/or system info
    if ($details.fields."System.WorkItemType" -eq "Bug") {
        if (![string]::IsNullOrEmpty($details.fields."Microsoft.VSTS.TCM.ReproSteps")) {
            # Fix line # reference in "Repository:" URL.
            $reproSteps = ($details.fields."Microsoft.VSTS.TCM.ReproSteps").Replace('/tree/', '/blob/').Replace('?&amp;path=', '').Replace('&amp;line=', '#L');
            $description += "## Repro Steps`n`n" + $reproSteps + "`n`n";
        }
        if (![string]::IsNullOrEmpty($details.fields."Microsoft.VSTS.TCM.SystemInfo")) {
            $description += "## System Info`n`n" + $details.fields."Microsoft.VSTS.TCM.SystemInfo" + "`n`n"
        }
    }
    else {
        $description += $details.fields."System.Description"
        # add in acceptance criteria if it has it
        if (![string]::IsNullOrEmpty($details.fields."Microsoft.VSTS.Common.AcceptanceCriteria")) {
            $description += "`n`n## Acceptance Criteria`n`n" + $details.fields."Microsoft.VSTS.Common.AcceptanceCriteria"
        }
    }

    # make linked pull requests visible within the GitHub UI by adding them to the description
    try {
        $_isGithubPrRelation = $relations.Values.Contains("GitHub Pull Request")
    }
    catch {
        $_isGithubPrRelation = $null
        Write-Error "Unable to search for GitHub Pull Request relation in $($relations)"
    }
    if ($_isGithubPrRelation) {
        $pr_description = "`n`n## Pull Requests`n`n"
        $pr_count = 0
        foreach ($relation in $relations.GetEnumerator()) {
            if ($relation.Value -eq "GitHub Pull Request") {
                $resolved_relation_url = Convert-AzureDevOpsLinkUrl -url $relation.Key -useMappedUrl $true

                $state = ${script:state}.GetGitHubPullRequestState($resolved_relation_url)
                if ($state -eq "MERGED") {
                    $pr_description += "- [x] Resolve $($resolved_relation_url)`n"
                }
                elseif ($state -eq "CLOSED") {
                    $pr_description += "- ~[ ] Resolve $($resolved_relation_url)~`n"
                }
                else {
                    $pr_description += "- [ ] Resolve $($resolved_relation_url)`n"
                }
                $pr_count++
            }
        }
        if ($pr_count -gt 0) {
            $description += $pr_description
        }
    }

    if (!$description) {
        $description = ":hear_no_evil: No description provided"
    }

    return $description
}


function Get-ItemNumberFromUrl() {
    param (
        [string] $url # the url of the issue to get the number from
    )
    return $url -split "/" | Select-Object -Last 1
}

function Get-GitHubIssueCommentAzureDevOpsDetails() {
    param(
        [PSCustomObject]$details
    )

    # use empty string if there is no user is assigned
    $ado_assigned_to_display_name = $details.fields."System.AssignedTo".displayName

    $ado_details_begin = "`n`n<details><summary>:information_source: Original Work Item Details</summary><p>`n`n"
    $ado_details_table = ""
    $ado_details_table += "| Created date | Created by | Changed date | Changed By | Assigned To | State | Type | Area Path | Iteration Path|`n|---|---|---|---|---|---|---|---|---|`n"
    $ado_details_table += "| $($details.fields."System.CreatedDate") | $($details.fields."System.CreatedBy".displayName) "
    $ado_details_table += "| $($details.fields."System.ChangedDate") | $($details.fields."System.ChangedBy".displayName) "
    $ado_details_table += "| $ado_assigned_to_display_name | $($details.fields."System.State") "
    $ado_details_table += "| $($details.fields."System.WorkItemType") | $($details.fields."System.AreaPath") "
    $ado_details_table += "| $($details.fields."System.IterationPath") |`n`n"
    $ado_details_end = "`n`n</p></details>"

    $ado_details = $ado_details_begin + $ado_details_table + $ado_details_end
    return $ado_details
}

function Get-GitHubIssueCommentHeader() {
    param(
        $relations, # the relations of the work item to get the description for
        $tags  # the tags of the work item to get the description for
    )

    $header = "## Azure Boards`n`n"
    $header += "[![](https://img.shields.io/badge/work--item-AB%23$($workitem.id)-0078D7?logo=azure-devops)]($(Convert-AzureDevOpsLinkUrl -url $workitem.url))` "

    # add links
    ForEach ($relation in $relations.GetEnumerator()) {
        $header += "$(Get-AzureDevOpsLinkShield -url $relation.Key -relationName $relation.Value)` "
    }

    ForEach ($tag in $($tags | ForEach-Object { $_.Trim() } | Select-Object -Unique )) {
        if ($tag) {
            $badgeUrl = "![$tag](https://img.shields.io/badge/tag-$($tag -replace " ", "-" -replace "-", "--")-E5E4E2)"
            $header += "$badgeUrl "
        }
    }
    return $header
}

function Get-GitHubIssueCommentAzureDevOpsRelations() {
    param(
        [Parameter(Mandatory = $true)][PSCustomObject]$relations, # the relations of the work item to get the description for
        [PSCustomObject]$azureDevOpsQuery = ${script:state}.azureDevOpsItemsQuery  # the details of the work item to get the description for
    )
    # create the relations table
    if ($relations) {
        $relation_details = "`n`n<details><summary>:card_file_box: Related Work Items</summary><p>" + "`n`n"
        $relation_details += "| Relationship | Link | Title |`n|---|---|---|`n"

        foreach ($relation in $relations.GetEnumerator()) {
            $relation_url = $relation.Key
            $relation_name = $relation.Value
            $relation_url = Convert-AzureDevOpsLinkUrl -url $relation_url -useMappedUrl $true
            $relation_issue_url = ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap["$relation_url"]

            $relation_title = $azureDevOpsQuery | Where-Object {
                $_.url -eq $relation_url -or $(Convert-AzureDevOpsLinkUrl -url $_.url) -eq $relation_url
            } | Select-Object -ExpandProperty fields | Select-Object -ExpandProperty "System.Title"

            # check if the link is a GitHub link
            if ($relation_name -match "GitHub") {
                # extract the id, repo and org from the url
                $split_url = $relation_url -replace "https://github.com/", "" -split "/"
                $inferred_url_org = $split_url[0]
                $inferred_url_repo = $split_url[1]
                $inferred_url_id = $split_url[-1]
                if ($gh_mention_related_items -eq $true -and -not $relation_name -match "Commit") {
                    $link_text = "${inferred_url_org}/${inferred_url_repo}#${inferred_url_id}"
                }
                elseif ($relation_name -match "Commit") {
                    $link_text = "${inferred_url_org}/${inferred_url_repo}@${inferred_url_id}"
                }
                else {
                    $link_text = "$inferred_url_org/${inferred_url_repo} ${inferred_url_id}"
                }
            }
            elseif ($relation_issue_url) {
                # always reference issues which we have already migrated
                $link_text = "#$(Get-ItemNumberFromUrl -url $relation_issue_url)"
            }
            elseif ($relation_url -match "https://dev.azure.com/") {
                $link_text = "Azure Boards AB#$(Get-ItemNumberFromUrl -url $relation_url)"
            }
            else {
                $link_text = ":link: link"
            }
            $relation_details += "| $relation_name | [$link_text]($relation_url) | $relation_title |`n"
        }
        $relation_details += "`n" + "`n</p></details>"
    }
    else {
        $relation_details = ""
    }
    return $relation_details
}

function Get-GitHubIssueCommentAzureDevOpsWorkItem() {
    param(
        [string]$detailsJson
    )
    # prepare the comment
    $fence = '```'
    $originalWorkitemJsonBeginning = "`n`n<details><summary>:scroll: Original Work Item JSON</summary><p>`n`n${fence}json`n"
    $prettyJson = $detailsJson | ConvertFrom-Json | ConvertTo-Json -Depth 100
    $originalWorkitemJsonEnd = "`n$fence`n`n</p></details>"
    return "$originalWorkitemJsonBeginning`n$prettyJson`n$originalWorkitemJsonEnd"
}

function Set-GitHubIssueAssignee() {
    param(
        [Parameter(Mandatory = $false)][string]$adoAssignedToUniqueName, # the Azure DevOps unique name of the assignee
        [Parameter(Mandatory = $true)][string]$issueUrl  # the url of the issue to set the assignee for
    )
    # update assigned to in GitHub if the option is set - tries to use ado email to map to github username
    if ($gh_update_assigned_to -eq $true -and $adoAssignedToUniqueName) {
        $assignee = ${script:config}.azureDevOpsEmailToGitHubAssigneeMap[$adoAssignedToUniqueName]
        if (!$assignee) {
            $assignee = ([string]$adoAssignedToUniqueName).Split("@")[0]
        }
        $previouslyAssigned = (
            Get-IsGithubIssueAssignedTo -assignee "$assignee" -issueUrl $issue_url -ErrorAction SilentlyContinue
        )
        if (!$previouslyAssigned) {
            Write-Output "  ↳ Trying to assign to: $assignee"
            $errorPath = "${script:TEMPORARY_DIRECTORY}/AB$workitemId.issue-assign.err"
            $assigned = gh issue edit $issueUrl --add-assignee "$assignee" 2>"$errorPath"
            if ($assigned) {
                Write-Host "    ↳ SUCCESS" -ForegroundColor Green
            }
            else {
                $errorReason = (
                    Get-Content -Path "$errorPath" 2>$null
                ).Replace("failed to update", "").Split(":")[1].Trim()
                Write-Host "    ↳ FAILED (${errorReason})" -ForegroundColor Red
            }
        }
    }
}

function Set-GitHubIssueMilestone() {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory = $true)][string]$milestone, # the milestone to set the issue to, e.g. "v1.0"
        [Parameter(Mandatory = $true)][string]$issueUrl  # the url of the issue to set the milestone for
    )
    if (Get-HasGithubIssueMilestone -milestone "$milestone" -issueUrl $issue_url) {
        Write-Output "  ↳ Issue already associated milestone: '$milestone'"
    }
    else {
        Write-Output "  ↳ Trying to set milestone to: '$milestone'"
        $result = gh issue edit $issueUrl --milestone "$milestone" 2>"${script:TEMPORARY_DIRECTORY}/AB$workitemId.issue-milestone.err"
        if ($result) {
            Write-Host "    ↳ SUCCESS" -ForegroundColor Green
        }
        else {
            Write-Host "    ↳ FAILED" -ForegroundColor Red
        }
    }
}

function Set-GitHubIssueLabel() {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [string]$label, # the label to set the issue to, e.g. "v1.0"
        [Parameter(Mandatory = $true)][string]$issueUrl, # the url of the issue to set the label for
        [string]$msg = "Adding label"
    )
    if (!$label) {
        return  # nothing to do
    }
    $previous_label = Get-HasGitHubIssueLabel -label $label -issueUrl $issue_url -ErrorAction SilentlyContinue
    if (!$previous_label) {
        if ($msg) {
            Write-Output "  ↳ ${msg}: '$label' "
        }
        if ($label -and (Get-HasGitHubRepositoryLabel -label "$label")) {
            $result = gh issue edit $issue_url --add-label "$label" 2>$null
            if ($result) {
                Write-Host "    ↳ SUCCESS" -ForegroundColor Green
            }
            else {
                Write-Host "    ↳ FAILED" -ForegroundColor Red
            }
        }
        else {
            Write-Host "    ↳ FAILED (no such label)" -ForegroundColor Red
        }
    }
}

function New-GitHubIssue() {
    [CmdletBinding(SupportsShouldProcess = $false)]
    param(
        [Parameter(Mandatory = $true)][string]$title, # the title of the issue to create
        [Parameter(Mandatory = $false)][string]$label, # the label of the issue to create
        [Parameter(Mandatory = $true)][string]$issueBodyFile, # the path to the file containing the issue body
        [Parameter(Mandatory = $true)][string]$workitemId, # the id of the work item to create the issue for
        [Parameter(Mandatory = $true)][string]$details, # the details of the work item to create the issue for
        [Parameter(Mandatory = $false)][string]$milestone = ""  # the milestone to assign the issue to
    )

    $apiResetAttempts = 0
    $errorReason = "Not Created"

    [string[]]$additionalFlags = @()
    if ("$milestone" -in ${script:state}.githubRepositoryInfo.milestones) {
        $additionalFlags += @("--milestone", "$milestone")
    }
    if ("$label") {
        $additionalFlags += @("--label", $label)
    }

    # setting the label on the issue to be the work item type
    $workItemType = "$($details.fields."System.WorkItemType")"
    if (${script:config}.azureDevOpsItemTypeToGitHubLabelMap.ContainsKey($workItemType)) {
        $label = ${script:config}.azureDevOpsItemTypeToGitHubLabelMap[$workItemType]
    } else {
        $label = $workItemType.ToLower()
    }

    if ($label) {
        $additionalFlags += @("--label", $label)
    }
    $sleepDuration = 903
    while ($errorReason -and $gh_wait_for_rate_limit_reset -and $apiResetAttempts -lt 6) {
        if ($apiResetAttempts -eq 0) {
            Write-Output "  ↳ Creating issue for work item AB#$($workitemId) with title: $title"
        }
        else {
            $errorMsg = "GitHub API rate limit exceeded [attempt #$($apiResetAttempts + 1)]"
            Write-Host "  ↳ $errorMsg - waiting 15 mins before retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds $sleepDuration  # add slight leeway offset just to be safe
        }
        $issueUrl = (
            gh issue create `
                --body-file "$issueBodyFile" `
                --project "$gh_project_name" `
                --title "$title" `
                @additionalFlags `
                2>"${script:TEMPORARY_DIRECTORY}/AB$workitemId.issue-create.err"
        )
        $errorReason = Get-Content -Path "${script:TEMPORARY_DIRECTORY}/AB$workitemId.issue-create.err" 2>$null
        $apiResetAttempts++
    }
    if ($issueUrl) {
        $issueUrl = $issueUrl.Trim()
        Write-Output "  ↳ Issue created: $issueUrl";
        $issueDetails = gh issue view $issueUrl --json $script:ISSUE_JSON_FIELDS | ConvertFrom-JSON
        if ($issueDetails) {
            $script:existingGitHubIssuesInformationTable[$issueUrl] = $issueDetails
        }
        $boardStatusString = ${script:config}.azureDevOpsStateToGitHubProjectColumnMap["$($details.fields."System.State")"]
        New-ProjectBoardItem `
            -project ${script:state}.githubProject `
            -issueUrl $issueUrl `
            -projectBoardStatus $boardStatusString
    } else {
        Write-Error "Issue creation failed for AB#${workitemId}. due to error: $errorReason"
    }
    return $issueDetails
}


# iterate through the work items and create GitHub issues if they don't already exist
ForEach ($workitem in $query) {
    $previously_created = $false
    $issue_url = ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$workitem.url]
    if ($issue_url) {
        $previously_created = $true
    }

    if ($previously_created -and -not $gh_update_existing_issues) {
        Write-Warning "Work item AB#$($workitem.id) already migrated to GitHub under: $issue_url"
        continue
    }

    $workitemId = $workitem.id;
    $temp_issue_body_file = [System.IO.DirectoryInfo]"${script:TEMPORARY_DIRECTORY}/AB$workitemId.temp_issue_body.txt"
    $temp_comment_body_file = [System.IO.DirectoryInfo]"${script:TEMPORARY_DIRECTORY}/AB$workitemId.temp_comment_body.txt"

    $details_json = az boards work-item show --id $workitem.id --output json
    $details = $details_json | ConvertFrom-Json

    # double quotes in the title must be escaped with \ to be passed to gh cli
    # workaround for https://github.com/cli/cli/issues/3425 and https://stackoverflow.com/questions/6714165/powershell-stripping-double-quotes-from-command-line-arguments
    $title = $details.fields."System.Title" -replace "`"", "`\`""

    $workitemType = $details.fields.'System.WorkItemType'
    Write-Output "Copying '$workitemType' work item $workitemId to $gh_org/$gh_repo on github";

    # create a map of relations URLs to names
    $relations = @{}
    if ($details.relations) {
        $details.relations | ForEach-Object { $relations[$_.url] = $_.attributes.name }
    }

    $tags = $details.fields."System.Tags" -split "; "
    $description = Get-GitHubIssueAzureDevOpsDescription -details $details -relations $relations
    $description | Out-File -FilePath $temp_issue_body_file -Encoding utf8;

    $comment_header = Get-GitHubIssueCommentHeader -relations $relations -tags $tags
    $comment_header | Out-File -FilePath $temp_comment_body_file -Encoding utf8;

    $ado_details = Get-GitHubIssueCommentAzureDevOpsDetails -details $details
    $ado_details | Add-Content -Path $temp_comment_body_file -Encoding utf8;

    $relation_details = Get-GitHubIssueCommentAzureDevOpsRelations -relations $relations
    $relation_details | Add-Content -Path $temp_comment_body_file -Encoding utf8;

    $original_workitem_json = Get-GitHubIssueCommentAzureDevOpsWorkItem -detailsJson $details_json
    $original_workitem_json | Add-Content -Path $temp_comment_body_file -Encoding utf8;

    # getting comments if enabled
    if ($gh_add_ado_comments -eq $true) {
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$ado_pat"))
        $headers.Add("Authorization", "Basic $base64")
        $response = Invoke-RestMethod "https://dev.azure.com/$ado_org/$ado_project/_apis/wit/workItems/$($workitem.id)/comments?api-version=7.1-preview.3" -Method 'GET' -Headers $headers

        if ($response.count -gt 0) {
            $ado_comments_details = ""
            $ado_original_workitem_json_beginning = "`n`n<details><summary>:speech_balloon: Work Item Comments ($($response.count))</summary><p>" + "`n`n"
            ForEach ($comment in $response.comments) {
                $ado_comments_details = "| Created date | Created by | JSON URL |`n|---|---|---|`n"
                $ado_comments_details += "| $($comment.createdDate) | $($comment.createdBy.displayName) | [URL]($($comment.url)) |`n`n"
                $ado_comments_details += "**Comment text**: $($comment.text)`n`n-----------`n`n"
            }
            $ado_original_workitem_json_end = "`n" + "`n</p></details>"
            "$ado_original_workitem_json_beginning$ado_comments_details$ado_original_workitem_json_end" | Add-Content -Path $temp_comment_body_file -Encoding utf8;
        }
    }

    # get milestone to assign work item to
    $milestone = "$gh_milestone_iteration_name_prefix$($details.fields."System.IterationLevel2")"

    if (-not $previously_created) {
        $issue_details = New-GitHubIssue `
            -title $title `
            -label "$label" `
            -issueBodyFile $temp_issue_body_file `
            -workitemId $workitemId `
            -details $details
        $issue_url = $issue_details.url

        if ($issue_url) {
            # map both long and short Azure DevOps URL variants to the same GitHub issue URL
            ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$workitem.url] = $issue_url
            ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap[$details.url] = $issue_url
        }
    }
    else {
        Write-Output "  ↳ Issue already created: $issue_url";
    }

    if (!$issue_url) {
        continue
    }

    $ado_assigned_to_unique_name = [string]$details.fields."System.AssignedTo".uniqueName
    Set-GitHubIssueAssignee -adoAssignedToUniqueName "$ado_assigned_to_unique_name" -issueUrl $issue_url

    # NOTE: Perform some less important updates to the issue after it is created, for instance we don't care if the tags don't exist
    Set-GitHubIssueMilestone -milestone "$milestone" -issueUrl $issue_url

    # add the labels, fail silently if the label doesn't exist
    $gh_labels | ForEach-Object { Set-GitHubIssueLabel -label "$_" -issueUrl $issue_url }

    # add mapped Azure DevOps tags as GitHub labels, fail silently if the label doesn't exist
    ForEach ($tag in $tags | Select-Object -Unique) {
        $label = ${script:config}.azureDevOpsTagsToGitHubLabelsMap["$tag"]
        Set-GitHubIssueLabel -label "$label" -issueUrl $issue_url -msg "Adding tag '$tag' as label"
    }

    Set-GitHubIssueLabel -label ${script:config}.azureDevOpsItemTypeToGitHubLabelMap["$workitemType"] -issueUrl $issue_url -msg "Adding '$workitemType' item type as label"

    # add the comment
    $comment = "$(Get-Content -Path $temp_comment_body_file -Raw)"
    $comment_url = $script:existingGitHubIssuesInformationTable[$issue_url].comments | Where-Object { $_.body -match "## Azure Boards" } | Select-Object -ExpandProperty "url" -First 1
    $previous_comment = $script:existingGitHubIssuesInformationTable[$issue_url].comments | Where-Object { $_.body -match "## Azure Boards" } | Select-Object -ExpandProperty "body" -First 1
    $comment_error = $false
    $comment_action = $null
    if (!$previously_created -or !$script:existingGitHubIssuesInformationTable[$issue_url].comments) {
        Write-Output "  ↳ Adding Azure DevOps migration comment"
        $comment_url = gh issue comment $issue_url --body-file $temp_comment_body_file
        $comment_action = "added"
    }
    elseif (($script:existingGitHubIssuesInformationTable[$issue_url] | Select-Object -ExpandProperty "comments").Count -lt 2) {
        if ($comment -ne $previous_comment) {
            Write-Output "  ↳ Updating Azure DevOps migration comment"
            $comment_url = gh issue comment $issue_url --body-file $temp_comment_body_file --edit-last 2>"$script:TEMPORARY_DIRECTORY/AB$workitemId.issue-comment.err"
            $comment_error = Get-Content -Path "$script:TEMPORARY_DIRECTORY/AB$workitemId.issue-comment.err" 2>$null
            if ($comment_error -match "no comments found") {
                $comment_url = gh issue comment $issue_url --body-file $temp_comment_body_file 2>"$script:TEMPORARY_DIRECTORY/AB$workitemId.issue-comment.err"
                $comment_action = "added"
            } else {
                $comment_action = "updated"
            }
        } else {
            $comment_action = "skipped"
        }
    } elseif (($script:existingGitHubIssuesInformationTable[$issue_url] | Select-Object -ExpandProperty "comments").Count -ge 2) {
        if ($comment -ne $previous_comment) {
            Write-Output "  ↳ Updating Azure DevOps migration comment"
            $comment_error = Update-GitHubComment -commentId $comment_url.Split("/")[-1].Split("#issuecomment-")[-1] -newComment $comment
            $comment_action = "added"
        }
    }
    if ($comment_url -and $comment_action) {
        Write-Host "    ↳ SUCCESS" -ForegroundColor Green
        Write-Output "    ↳ Comment ${comment_action}: $comment_url"
    } elseif ($comment_error){
        Write-Host "    ↳ FAILED" -ForegroundColor Red
    }

    Remove-Item -Path $temp_comment_body_file -ErrorAction SilentlyContinue
    Remove-Item -Path $temp_issue_body_file -ErrorAction SilentlyContinue

    # Add the tag "copied-to-github" plus a comment to the work item
    if ($ado_production_run) {
        $workitemTags = $workitem.fields.'System.Tags';
        $discussion = "This work item was copied to github as issue <a href=`"$issue_url`">$issue_url</a>";
        $result = az boards work-item update --id "$workitemId" --fields "System.Tags=copied-to-github; $workitemTags" --discussion "$discussion";
        if ($result) {
            Write-Output "  ↳ ADO work item $workitemId updated with tag 'copied-to-github'"
        }
    }

    # close out the issue if it's closed on the Azure Devops side
    $ado_closure_states = "Done", "Closed", "Resolved", "Removed"
    if ($ado_closure_states.Contains($details.fields."System.State")) {
        if (
            $gh_archive_closed_items_label -and `
            (Get-HasGitHubRepositoryLabel -label "$gh_archive_closed_items_label") -and `
            !$(Get-HasGitHubIssueLabel -label "$gh_archive_closed_items_label" -issueUrl $issue_url)
        ) {
            $result = gh issue edit $issue_url --add-label $gh_archive_closed_items_label
            Write-Output "  ↳ Marking issue as archived with label: '$gh_archive_closed_items_label' "
            if ($result) {
                Write-Host "    ↳ SUCCESS" -ForegroundColor Green
            }
            else {
                Write-Host "    ↳ FAILED" -ForegroundColor Red
            }
        }
        if ($(Get-GithubIssueState -issueUrl $issue_url) -notin @( "CLOSED", "MERGED" )) {
            Write-Output "  ↳ Closing issue as it is closed in Azure DevOps"
            $closing_comment = "Corresponding Azure DevOps board item AB#$workitemId is closed or done"
            $result = gh issue close $issue_url --comment "$closing_comment" --reason "completed" 2>"${script:TEMPORARY_DIRECTORY}/AB$workitemId.issue-close.err"
            $error_reason = (Get-Content -Path "${script:TEMPORARY_DIRECTORY}/AB$workitemId.issue-close.err" 2>$null)
            if ($result -or $error_reason -match "✓ Closed issue") {
                $result = $result | ConvertFrom-Json
                Write-Host "    ↳ SUCCESS" -ForegroundColor Green
            } else {
                Write-Host "    ↳ FAILED ($error_reason)" -ForegroundColor Red
            }
        }
    }

    Save-MapToJSON -map ${script:state}.azureDevOpsWorkItemUrlToGitHubIssueUrlMap -path "$ado_to_gh_workitem_checkpoint_file"

    $count++

}
Write-Output "Total items copied: $count"
