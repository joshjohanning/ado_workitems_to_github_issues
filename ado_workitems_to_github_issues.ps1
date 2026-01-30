##############################################################
# Migrate Azure DevOps work items to GitHub Issues
##############################################################

# Prerequisites:
# 1. Install az devops and github cli
# 2. create a label for EACH work item type that is being migrated (as lower case) 
#      - ie: "user story", "bug", "task", "feature"
# 3. define under what area path you want to migrate
#      - You can modify the WIQL if you want to use a different way to migrate work items, such as [TAG] = "migrate"

# How to run:
# ./ado_workitems_to_github_issues.ps1 -ado_pat "xxx" -ado_org "jjohanning0798" -ado_project "PartsUnlimited" -ado_area_path "PartsUnlimited\migrate"  -gh_pat "xxx" -gh_org "joshjohanning-org" -gh_repo "migrate-ado-workitems" -gh_assigned_to_user_suffix "_corp"

# Optional switches to add - if you add this parameter, this means you want it set to TRUE (for false, simply do not provide)
# -ado_migrate_closed_workitems
# -ado_production_run
# -gh_update_assigned_to
# -gh_add_ado_comments

#
# Things it migrates:
# 1. Title
# 2. Description (or repro steps + system info for a bug)
# 3. State (if the work item is done / closed, it will be closed in GitHub)
# 4. It will try to assign the work item to the correct user in GitHub - based on ADO email (-gh_update_assigned_to and -gh_assigned_to_user_suffix options) - they of course have to be in GitHub already
# 5. Migrate acceptance criteria as part of issue body (if present)
# 6. Adds in the following as a comment to the issue:
#   a. Original work item url 
#   b. Basic details in a collapsed markdown table
#   c. Entire work item as JSON in a collapsed section
# 7. Creates tag "copied-to-github" and a comment on the ADO work item with `-$ado_production_run` . The tag prevents duplicate copying.
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
    [switch]$ado_migrate_closed_workitems, # migrate work items with the state of done, closed, resolved, and removed
    [switch]$ado_production_run, # tag migrated work items with 'migrated-to-github' and add discussion comment
    [string]$gh_pat, # GitHub PAT
    [string]$gh_org, # GitHub organization to create the issues in
    [string]$gh_repo, # GitHub repository to create the issues in
    [switch]$gh_update_assigned_to, # try to update the assigned to field in GitHub
    [string]$gh_assigned_to_user_suffix = "", # the emu suffix, ie: "_corp"
    [switch]$gh_add_ado_comments # try to get ado comments
)

# Error handling function
function Write-Error-Host {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Write-Success-Host {
    param([string]$Message)
    Write-Host "SUCCESS: $Message" -ForegroundColor Green
}

function Write-Info-Host {
    param([string]$Message)
    Write-Host "INFO: $Message" -ForegroundColor Cyan
}

# Validate required parameters
Write-Info-Host "Validating required parameters..."

if ([string]::IsNullOrEmpty($ado_pat)) {
    Write-Error-Host "ADO_PAT is required but not provided"
    exit 1
} else {
    Write-Success-Host "ADO_PAT is set (length: $($ado_pat.Length) characters)"
}

if ([string]::IsNullOrEmpty($gh_pat)) {
    Write-Error-Host "GH_PAT is required but not provided"
    exit 1
} else {
    Write-Success-Host "GH_PAT is set (length: $($gh_pat.Length) characters)"
}

if ([string]::IsNullOrEmpty($ado_org)) {
    Write-Error-Host "ado_org is required but not provided"
    exit 1
} else {
    Write-Success-Host "ado_org: $ado_org"
}

if ([string]::IsNullOrEmpty($ado_project)) {
    Write-Error-Host "ado_project is required but not provided"
    exit 1
} else {
    Write-Success-Host "ado_project: $ado_project"
}

if ([string]::IsNullOrEmpty($ado_area_path)) {
    Write-Error-Host "ado_area_path is required but not provided"
    exit 1
} else {
    Write-Success-Host "ado_area_path: $ado_area_path"
}

if ([string]::IsNullOrEmpty($gh_org)) {
    Write-Error-Host "gh_org is required but not provided"
    exit 1
} else {
    Write-Success-Host "gh_org: $gh_org"
}

if ([string]::IsNullOrEmpty($gh_repo)) {
    Write-Error-Host "gh_repo is required but not provided"
    exit 1
} else {
    Write-Success-Host "gh_repo: $gh_repo"
}

# Check dependencies
Write-Info-Host "Checking dependencies..."

try {
    $azVersion = az --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Host "Azure CLI (az) is not installed or not in PATH"
        exit 1
    }
    Write-Success-Host "Azure CLI (az) is available"
} catch {
    Write-Error-Host "Failed to check Azure CLI: $_"
    exit 1
}

try {
    $ghVersion = gh --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Host "GitHub CLI (gh) is not installed or not in PATH"
        exit 1
    }
    Write-Success-Host "GitHub CLI (gh) is available"
} catch {
    Write-Error-Host "Failed to check GitHub CLI: $_"
    exit 1
}

# Set the auth token for az commands
Write-Info-Host "Setting authentication tokens..."
try {
    $env:AZURE_DEVOPS_EXT_PAT = $ado_pat
    $env:GH_TOKEN = $gh_pat
    Write-Success-Host "Authentication tokens set"
} catch {
    Write-Error-Host "Failed to set authentication tokens: $_"
    exit 1
}

# Configure Azure DevOps defaults
Write-Info-Host "Configuring Azure DevOps defaults..."
try {
    az devops configure --defaults organization="https://dev.azure.com/$ado_org" project="$ado_project" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Host "Failed to configure Azure DevOps defaults. Check your ADO_PAT and organization/project names."
        exit 1
    }
    Write-Success-Host "Azure DevOps defaults configured"
} catch {
    Write-Error-Host "Exception configuring Azure DevOps: $_"
    exit 1
}

# Build WIQL query
Write-Info-Host "Building WIQL query..."
$closed_wiql = ""
if (!$ado_migrate_closed_workitems) {
    $closed_wiql = "[State] <> 'Done' and [State] <> 'Closed' and [State] <> 'Resolved' and [State] <> 'Removed' and "
    Write-Info-Host "Excluding closed work items from migration"
} else {
    Write-Info-Host "Including closed work items in migration"
}

$wiql = "select [ID], [Title], [System.Tags] from workitems where $closed_wiql[System.AreaPath] UNDER '$ado_area_path' and not [System.Tags] Contains 'copied-to-github' order by [ID]"
Write-Info-Host "WIQL Query: $wiql"

# Query work items
Write-Info-Host "Querying work items from Azure DevOps..."
try {
    $queryResult = az boards query --wiql $wiql 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Host "Failed to query work items. Error: $queryResult"
        exit 1
    }
    $query = $queryResult | ConvertFrom-Json
    if ($null -eq $query) {
        Write-Error-Host "Failed to parse work items query result"
        exit 1
    }
    Write-Success-Host "Found $($query.Count) work item(s) to migrate"
} catch {
    Write-Error-Host "Exception querying work items: $_"
    exit 1
}

$count = 0;

ForEach($workitem in $query) {
    $workitemId = $workitem.id;
    Write-Info-Host "Processing work item ID: $workitemId"

    try {
        $details_json = az boards work-item show --id $workitem.id --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Host "Failed to retrieve work item $workitemId. Error: $details_json"
            continue
        }
        $details = $details_json | ConvertFrom-Json
        if ($null -eq $details) {
            Write-Error-Host "Failed to parse work item $workitemId details"
            continue
        }
    } catch {
        Write-Error-Host "Exception retrieving work item $workitemId : $_"
        continue
    }

    # double quotes in the title must be escaped with \ to be passed to gh cli
    # workaround for https://github.com/cli/cli/issues/3425 and https://stackoverflow.com/questions/6714165/powershell-stripping-double-quotes-from-command-line-arguments
    try {
        $title = $details.fields.{System.Title} -replace "`"","`\`""
        if ([string]::IsNullOrEmpty($title)) {
            Write-Error-Host "Work item $workitemId has an empty title, skipping"
            continue
        }
    } catch {
        Write-Error-Host "Exception processing title for work item $workitemId : $_"
        continue
    }

    Write-Info-Host "Copying work item $workitemId to $gh_org/$gh_repo on GitHub"

    $description=""

    # bug doesn't have Description field - add repro steps and/or system info
    try {
        if ($details.fields.{System.WorkItemType} -eq "Bug") {
            if(![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.TCM.ReproSteps})) {
                # Fix line # reference in "Repository:" URL.
                $reproSteps = ($details.fields.{Microsoft.VSTS.TCM.ReproSteps}).Replace('/tree/', '/blob/').Replace('?&amp;path=', '').Replace('&amp;line=', '#L');
                $description += "## Repro Steps`n`n" + $reproSteps + "`n`n";
            }
            if(![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.TCM.SystemInfo})) {
                $description+="## System Info`n`n" + $details.fields.{Microsoft.VSTS.TCM.SystemInfo} + "`n`n"
            }
        } else {
            if ($null -ne $details.fields.{System.Description}) {
                $description+=$details.fields.{System.Description}
            }
            # add in acceptance criteria if it has it
            if(![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.Common.AcceptanceCriteria})) {
                $description+="`n`n## Acceptance Criteria`n`n" + $details.fields.{Microsoft.VSTS.Common.AcceptanceCriteria}
            }
        }
    } catch {
        Write-Error-Host "Exception building description for work item $workitemId : $_"
        # Continue with empty description, will be handled below
    }

    $gh_comment="[Original Work Item URL](https://dev.azure.com/$ado_org/$ado_project/_workitems/edit/$($workitem.id))"
    
    # use empty string if there is no user is assigned
    if ( $null -ne $details.fields.{System.AssignedTo}.displayName )
    {
        $ado_assigned_to_display_name = $details.fields.{System.AssignedTo}.displayName
        $ado_assigned_to_unique_name = $details.fields.{System.AssignedTo}.uniqueName
    }
    else {
        $ado_assigned_to_display_name = ""
        $ado_assigned_to_unique_name = ""
    }
    
    # create the details table
    $gh_comment+="`n`n<details><summary>Original Work Item Details</summary><p>" + "`n`n"
    $gh_comment+= "| Created date | Created by | Changed date | Changed By | Assigned To | State | Type | Area Path | Iteration Path|`n|---|---|---|---|---|---|---|---|---|`n"
    $gh_comment+="| $($details.fields.{System.CreatedDate}) | $($details.fields.{System.CreatedBy}.displayName) | $($details.fields.{System.ChangedDate}) | $($details.fields.{System.ChangedBy}.displayName) | $ado_assigned_to_display_name | $($details.fields.{System.State}) | $($details.fields.{System.WorkItemType}) | $($details.fields.{System.AreaPath}) | $($details.fields.{System.IterationPath}) |`n`n"
    $gh_comment+="`n" + "`n</p></details>"

    # prepare the comment

    # getting comments if enabled
    if($gh_add_ado_comments -eq $true) {
        try {
            Write-Info-Host "  Retrieving comments for work item $workitemId"
            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
            $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$ado_pat"))
            $headers.Add("Authorization", "Basic $base64")
            $response = Invoke-RestMethod "https://dev.azure.com/$ado_org/$ado_project/_apis/wit/workItems/$($workitem.id)/comments?api-version=7.1-preview.3" -Method 'GET' -Headers $headers -ErrorAction Stop
            
            if($null -ne $response -and $null -ne $response.count -and $response.count -gt 0) {
                Write-Info-Host "  Found $($response.count) comment(s)"
                $gh_comment+="`n`n<details><summary>Work Item Comments ($($response.count))</summary><p>" + "`n`n"
                ForEach($comment in $response.comments) {
                    $gh_comment+= "| Created date | Created by | JSON URL |`n|---|---|---|`n"
                    $gh_comment+="| $($comment.createdDate) | $($comment.createdBy.displayName) | [URL]($($comment.url)) |`n`n"
                    $gh_comment+="**Comment text**: $($comment.text)`n`n-----------`n`n"
                }
                $gh_comment+="`n" + "`n</p></details>"
            } else {
                Write-Info-Host "  No comments found for work item $workitemId"
            }
        } catch {
            Write-Error-Host "  Exception retrieving comments for work item $workitemId : $_"
            # Continue without comments
        }
    }
    
    # setting the label on the issue to be the work item type
    $work_item_type = $details.fields.{System.WorkItemType}.ToLower()
    Write-Info-Host "  Work item type: $work_item_type"

    try {
        $issueHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $issueHeaders.Add("Authorization", "token $gh_pat")
        $issueHeaders.Add("Accept", "application/vnd.github.golden-comet-preview+json")
        $issueHeaders.Add("Content-Type", "application/json")

        Write-Info-Host "  Migrating https://dev.azure.com/$ado_org/$ado_project/_workitems/edit/$($workitem.id)"

        if ([string]::IsNullOrEmpty($description)){
            # Can't have an empty body on this API, so add work item url
            $description = "[Original Work Item URL](https://dev.azure.com/$ado_org/$ado_project/_workitems/edit/$($workitem.id))"
        }

        $params = @{
            issue = @{
                title = "$title"
                body = "$description"
            }
            comments = @(@{
                body = "$gh_comment"
            })
        } | ConvertTo-Json -Depth 10

        Write-Info-Host "  Creating GitHub issue..."
        $issueMigrateResponse = Invoke-RestMethod "https://api.github.com/repos/$gh_org/$gh_repo/import/issues" -Method 'POST' -Body $params -Headers $issueHeaders -ErrorAction Stop

        Write-Info-Host "  Issue import initiated, status URL: $($issueMigrateResponse.url)"
        
        if ($null -eq $issueMigrateResponse -or [string]::IsNullOrEmpty($issueMigrateResponse.url)) {
            throw "Invalid response from GitHub API - missing status URL"
        }

        $issue_url = ""
        $maxRetries = 60  # Maximum 60 seconds wait
        $retryCount = 0
        
        while($retryCount -lt $maxRetries) {
            Write-Info-Host "  Checking import status (attempt $($retryCount + 1)/$maxRetries)..."
            Start-Sleep -Seconds 1
            
            try {
                $issueCreationResponse = Invoke-RestMethod $issueMigrateResponse.url -Method 'GET' -Headers $issueHeaders -StatusCodeVariable 'statusCode' -ErrorAction Stop

                if ($statusCode -eq 404) {
                    Write-Info-Host "  Import status not yet available (404), retrying..."
                    $retryCount++
                    continue
                }

                if ($statusCode -ne 200) {
                    throw "Issue creation failed with status code $statusCode"
                }

                if ($issueCreationResponse.status -eq "imported") {
                    $issue_url = $issueCreationResponse.issue_url
                    Write-Success-Host "  Issue imported successfully: $issue_url"
                    break
                } elseif ($issueCreationResponse.status -eq "failed") {
                    throw "Issue creation failed with message: $($issueCreationResponse | ConvertTo-Json)"
                } elseif ($issueCreationResponse.status -eq "pending" -or $issueCreationResponse.status -eq "importing") {
                    Write-Info-Host "  Import status: $($issueCreationResponse.status), waiting..."
                    $retryCount++
                    continue
                } else {
                    Write-Info-Host "  Unknown import status: $($issueCreationResponse.status), waiting..."
                    $retryCount++
                    continue
                }
            } catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                    Write-Info-Host "  Import status not yet available (404), retrying..."
                    $retryCount++
                    continue
                } else {
                    throw "Exception checking import status: $_"
                }
            }
        }
        
        if ($retryCount -ge $maxRetries) {
            throw "Timeout waiting for issue import to complete after $maxRetries seconds"
        }
        
        if ([string]::IsNullOrEmpty($issue_url.Trim())) {
            throw "Issue creation failed - no issue URL returned"
        }
        
        Write-Success-Host "  Issue created: $issue_url"
        $count++;
    } catch {
        Write-Error-Host "Exception creating GitHub issue for work item $workitemId : $_"
        continue
    }
    
    # update assigned to in GitHub if the option is set - tries to use ado email to map to github username
    if ($gh_update_assigned_to -eq $true -and $ado_assigned_to_unique_name -ne "") {
        try {
            $gh_assignee=$ado_assigned_to_unique_name.Split("@")[0]
            $gh_assignee=$gh_assignee.Replace(".", "-") + $gh_assigned_to_user_suffix
            Write-Info-Host "  Attempting to assign issue to: $gh_assignee"
            $assigned = gh issue edit $issue_url --add-assignee "$gh_assignee" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success-Host "  Successfully assigned issue to $gh_assignee"
            } else {
                Write-Error-Host "  Failed to assign issue to $gh_assignee. Error: $assigned"
                # Continue - assignment failure is not critical
            }
        } catch {
            Write-Error-Host "  Exception assigning issue to GitHub user: $_"
            # Continue - assignment failure is not critical
        }
    }

    # Add the tag "copied-to-github" plus a comment to the work item
    if ($ado_production_run) {
        try {
            Write-Info-Host "  Tagging work item $workitemId as copied-to-github"
            $workitemTags = $workitem.fields.'System.Tags';
            $discussion = "This work item was copied to github as issue <a href=`"$issue_url`">$issue_url</a>";
            $tagResult = az boards work-item update --id "$workitemId" --fields "System.Tags=copied-to-github; $workitemTags" --discussion "$discussion" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success-Host "  Successfully tagged work item $workitemId"
            } else {
                Write-Error-Host "  Failed to tag work item $workitemId. Error: $tagResult"
                # Continue - tagging failure is not critical
            }
        } catch {
            Write-Error-Host "  Exception tagging work item $workitemId : $_"
            # Continue - tagging failure is not critical
        }
    }

    # close out the issue if it's closed on the Azure Devops side
    try {
        $ado_closure_states = @("Done","Closed","Resolved","Removed")
        if ($ado_closure_states -contains $details.fields.{System.State}) {
            Write-Info-Host "  Closing GitHub issue (ADO state: $($details.fields.{System.State}))"
            $closeResult = gh issue close $issue_url 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success-Host "  Successfully closed GitHub issue"
            } else {
                Write-Error-Host "  Failed to close GitHub issue. Error: $closeResult"
                # Continue - closing failure is not critical
            }
        }
    } catch {
        Write-Error-Host "  Exception closing GitHub issue: $_"
        # Continue - closing failure is not critical
    }
    
    Write-Success-Host "Completed processing work item $workitemId"
    Write-Host ""
}

Write-Host ""
Write-Success-Host "Migration completed! Total items copied: $count"
