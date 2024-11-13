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

# Set the auth token for az commands
$env:AZURE_DEVOPS_EXT_PAT = $ado_pat;
# Set the auth token for gh commands
$env:GH_TOKEN = $gh_pat;

az devops configure --defaults organization="https://dev.azure.com/$ado_org" project="$ado_project"

# add the wiql to not migrate closed work items
if (!$ado_migrate_closed_workitems) {
    $closed_wiql = "[State] <> 'Done' and [State] <> 'Closed' and [State] <> 'Resolved' and [State] <> 'Removed' and"
}

$wiql = "select [ID], [Title], [System.Tags] from workitems where $closed_wiql [System.AreaPath] UNDER '$ado_area_path' and not [System.Tags] Contains 'copied-to-github' order by [ID]";

$query=az boards query --wiql $wiql | ConvertFrom-Json

$count = 0;

ForEach($workitem in $query) {
    $original_workitem_json_beginning="`n`n<details><summary>Original Work Item JSON</summary><p>" + "`n`n" + '```json'
    $original_workitem_json_end="`n" + '```' + "`n</p></details>"

    $workitemId = $workitem.id;

    $details_json = az boards work-item show --id $workitem.id --output json
    $details = $details_json | ConvertFrom-Json

    # double quotes in the title must be escaped with \ to be passed to gh cli
    # workaround for https://github.com/cli/cli/issues/3425 and https://stackoverflow.com/questions/6714165/powershell-stripping-double-quotes-from-command-line-arguments
    $title = $details.fields.{System.Title} -replace "`"","`\`""

    Write-Host "Copying work item $workitemId to $gh_org/$gh_repo on github";

    $description=""

    # bug doesn't have Description field - add repro steps and/or system info
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
        $description+=$details.fields.{System.Description}
        # add in acceptance criteria if it has it
        if(![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.Common.AcceptanceCriteria})) {
            $description+="`n`n## Acceptance Criteria`n`n" + $details.fields.{Microsoft.VSTS.Common.AcceptanceCriteria}
        }
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
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$ado_pat"))
        $headers.Add("Authorization", "Basic $base64")
        $response = Invoke-RestMethod "https://dev.azure.com/$ado_org/$ado_project/_apis/wit/workItems/$($workitem.id)/comments?api-version=7.1-preview.3" -Method 'GET' -Headers $headers
        
        if($response.count -gt 0) {
            $gh_comment+="`n`n<details><summary>Work Item Comments ($($response.count))</summary><p>" + "`n`n"
            ForEach($comment in $response.comments) {
                $gh_comment+= "| Created date | Created by | JSON URL |`n|---|---|---|`n"
                $gh_comment+="| $($comment.createdDate) | $($comment.createdBy.displayName) | [URL]($($comment.url)) |`n`n"
                $gh_comment+="**Comment text**: $($comment.text)`n`n-----------`n`n"
            }
            $gh_comment+="`n" + "`n</p></details>"
        }
    }
    
    # setting the label on the issue to be the work item type
    $work_item_type = $details.fields.{System.WorkItemType}.ToLower()

    $issueHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $issueHeaders.Add("Authorization", "token $gh_pat")
    $issueHeaders.Add("Accept", "application/vnd.github.golden-comet-preview+json")
    $issueHeaders.Add("Content-Type", "application/json")

    Write-Host "Migrating https://dev.azure.com/$ado_org/$ado_project/_workitems/edit/$($workitem.id)"

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
    } | ConvertTo-Json

    Write-Host "  Issue creation request: $params";
    $issueMigrateResponse = Invoke-RestMethod  https://api.github.com/repos/$gh_org/$gh_repo/import/issues -Method 'POST' -Body $params -Headers $issueHeaders

    Write-Host "  Issue creation response: $issueMigrateResponse";
    $issue_url = ""
    while($true) {
        Write-Host "Sleeping for 1 seconds..."
        Start-Sleep -Seconds 1
        $issueCreationResponse = Invoke-RestMethod $issueMigrateResponse.url -Method 'GET' -Headers $issueHeaders -StatusCodeVariable 'statusCode'

        Write-Host "  Issue creation response: $issueCreationResponse";
        Write-Host "  Status code: $statusCode";
        if ($statusCode -eq 404) {
            continue
        }

        if ($statusCode -ne 200) {
            throw "Issue creation failed with status code $statusCode"
        }

        if ($issueCreationResponse.status -eq "imported") {
            $issue_url = $issueCreationResponse.issue_url
            break
        } elseif ($issueCreationResponse.status -eq "failed") {
            throw "Issue creation failed with message $issueCreationResponse"
        }
    }
    
    if (![string]::IsNullOrEmpty($issue_url.Trim())) {
        Write-Host "  Issue created: $issue_url";
        $count++;
    }
    else {
        throw "Issue creation failed.";
    }
    
    # update assigned to in GitHub if the option is set - tries to use ado email to map to github username
    if ($gh_update_assigned_to -eq $true -and $ado_assigned_to_unique_name -ne "") {
        $gh_assignee=$ado_assigned_to_unique_name.Split("@")[0]
        $gh_assignee=$gh_assignee.Replace(".", "-") + $gh_assigned_to_user_suffix
        write-host "  trying to assign to: $gh_assignee"
        $assigned=gh issue edit $issue_url --add-assignee "$gh_assignee"
    }

    # Add the tag "copied-to-github" plus a comment to the work item
    if ($ado_production_run) {
        $workitemTags = $workitem.fields.'System.Tags';
        $discussion = "This work item was copied to github as issue <a href=`"$issue_url`">$issue_url</a>";
        az boards work-item update --id "$workitemId" --fields "System.Tags=copied-to-github; $workitemTags" --discussion "$discussion" | Out-Null;    
    }

    # close out the issue if it's closed on the Azure Devops side
    $ado_closure_states = "Done","Closed","Resolved","Removed"
    if ($ado_closure_states.Contains($details.fields.{System.State})) {
        gh issue close $issue_url
    }
    
}
Write-Host "Total items copied: $count"
