using namespace System.Net
param($Request, $TriggerMetadata)

Write-Information ("Incoming {0} {1}" -f $Request.Method,$Request.Url)

Function ImmediateFailure ($Message) {
    Write-Error $Message
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        headers    = @{'content-type' = 'application\json' }
        StatusCode = [httpstatuscode]::OK
        Body       = @{"Error" = $Message } | convertto-json
    })
    exit 1
}

function Build-Body ($whitelistObj, $sourceObj, $depth) {
    # store a depth counter to avoid looping.
    if ($depth -isnot [int]) {
        $depth = 1
    } else {
        $depth++
    }
    if ($depth -gt 8) {
        Write-Error "Possible recursion loop or source object is deeper than expected."
        Return
    } 
    if (-not $sourceObj) {
        Return
    }
    if ($whitelistObj -is [hashtable] -or $whitelistObj -is [System.Collections.Specialized.OrderedDictionary]) {
        # When the whitelist object is a dictionary, loop over the keys and if they exist in the 
        # source object, recurse. Note that any extra keys will not be checked or logged.
        $counter = 0
        $newObject = [pscustomObject]@{}
        foreach ($key in $whitelistObj.keys) {
            if (Get-Member -inputobject $sourceObj -name $key -Membertype Properties) {
                $counter++
                $defaultValue = $null
				if ($whitelistObj[$key] -eq "bool") {
					$defaultValue = $false
				}
				$newObject | Add-Member -NotePropertyName $key -NotePropertyValue $defaultValue
                if ($sourceObj.$key) {
					if ($sourceObj.$key -is [array]) {
						# forces existing arrays to stay as arrays. Without this, arrays with 1 item get reduced to just that item (not in an array).
						$newObject.$key = @(Build-Body -whitelistObj $whitelistObj[$key] -sourceObj $sourceObj.$key -depth $depth)
					} else {
						$newObject.$key = Build-Body -whitelistObj $whitelistObj[$key] -sourceObj $sourceObj.$key -depth $depth
					}
				} elseif (-not $sourceObj.$key) {
					$newObject.$key = $sourceObj.$key # to keep falsy values
				}
            }
            Write-Debug ("{0}/{1} keys were whitelisted from the source dictionary." -f $counter, $sourceObj.length)
        }
    } elseif ($whitelistObj -is [System.Collections.Generic.List`1[System.Object]] -and $whitelistObj.length -eq 1) {
        # When the whitelist object is a list with a single member, loop over the source and store the results in an array.
        $newObject = @()
        foreach ($item in $sourceObj) {
            $newObject += Build-Body -whitelistObj $whitelistObj[0] -sourceObj $item -depth $depth
        }
    } elseif ($whitelistObj -is [string]) {
        # When the whitelist object is a string, store the value of the source object and move on.
        # Note that if the value is a list/dict, it will still add everything.
        # TODO: Validate source object data types.
        $newObject = $sourceObj
    } else {
        Write-Error "Unexpected format of whitelist object. Check your configuration: $($whitelistObj | ConvertTo-Json -Depth 2)"
        Return
    }
    Return $newObject
}
$clientToken = $request.headers.'x-api-key'

# Get a list of all the API Keys. Find the correct API Key if it exists.
# TODO: I have api key in ITG as a password but it is only returned (visible) when querying for the password by its ID
#       and this script doesn't know the ID of the password. We can probably query by ORG ID with filter_name
#       and get it, but then we will have to query again to get the password. So for now, we just use one key and an 
#       environment variable.
$ApiKeys = (Get-ChildItem env:APIKey_*)
$ApiKey = $ApiKeys | Where-Object { $_.Value -eq $clientToken }

# Check if the client's API token matches our stored version and that it's not too short.
# Without this check, a misconfigured environmental variable could allow unauthenticated access.
if (!$ApiKey -or $ApiKey.Value.Length -lt 14 -or $clientToken -ne $ApiKey.Value) {
    ImmediateFailure "401 - API token does not match"
}

## Whitelisting endpoints & data.
Import-Module powershell-yaml -Function ConvertFrom-Yaml
$endpoints = Get-Content -Raw ($TriggerMetadata.FunctionDirectory + "\..\whitelisted-endpoints.yml") | ConvertFrom-Yaml -Ordered

$resource_types = @('checklists', 'checklist_templates', 'configurations', 'contacts', 'documents', `
                    'domains', 'locations', 'passwords', 'ssl_certificates', 'flexible_assets', 'tickets')

$resourceUri = $request.Query.ResourceURI
$resourceUri_generic = ([string]$resourceUri).TrimEnd("/") -replace "/\d+","/:id"
$resourceUri_generic_by_type = [string]$resourceUri_generic
foreach ($type in $resource_types) {
    $resourceUri_generic_by_type = $resourceUri_generic_by_type -replace "\/$type","/:type"
}

# Log the body of the request if the debug level is trace. 
Write-Verbose ("Incoming Body: {0}" -f ($Request.Body|ConvertTo-Json -depth 6))

# Check to see if the called API endpoint & method has been whitelisted.
foreach ($key in $endpoints.keys) {
    if (($endpoints[$key].endpoints -contains $resourceUri_generic -or $endpoints[$key].endpoints -contains $resourceUri_generic_by_type) -and 
            $endpoints[$key].methods -contains $request.Method) {
        $endpointKey = $key
        break
    }
}
if (-not $endpointKey) {
    ImmediateFailure "401 - Unauthorized endpoint or method: $resourceUri"
}

# Build new query string from required and whitelisted parameters
$itgQuery = [System.Web.HttpUtility]::ParseQueryString([String]::Empty)
foreach ($filter in $endpoints[$endpointKey].required_parameters.Keys) {
    $itgQuery.Add($filter, $endpoints[$endpointKey].required_parameters.$filter)
}
foreach ($filter in $endpoints[$endpointKey].allowed_parameters) {
    if ($request.Query.$filter) {
        $itgQuery.Add($filter, $request.Query.$filter)
    }
}

# Combine resource URI and query string
$uriBuilder = [System.UriBuilder]("{0}{1}" -f $ENV:ITGlueURI,$resourceUri)
$uriBuilder.Query = $itgQuery.ToString()
$itgUri = $uriBuilder.Uri.OriginalString
Write-Information ("Outgoing {0} {1}" -f $Request.Method,$itgUri)

# Construct new request for IT Glue
$itgHeaders = @{"x-api-key" = $ENV:ITGlueAPIKey}
$itgMethod = $Request.Method
if ($request.body) {
    $oldBody = $request.body | convertfrom-json
    $itgBody = Build-Body $endpoints[$endpointKey].createbody $oldBody
    $itgBodyJson = $itgBody | ConvertTo-Json -Depth 6
} else {
    $itgBodyJson = $null
}

# Log outgoing body if the debug level is trace. 
Write-Verbose "Outgoing body: $itgBodyJson"

# Send request to IT Glue
$SuccessfullQuery = $false
$attempt = 2
while ($attempt -gt 0 -and -not $SuccessfullQuery) {
    try {
        $itgRequest = Invoke-RestMethod -Method $itgMethod -ContentType "application/vnd.api+json" `
                                        -Uri $itgUri -Body $itgBodyJson -Headers $itgHeaders
        $SuccessfullQuery = $true
    } catch {
        $attempt--
        if ($attempt -eq 0) {
            Write-Debug $_.Exception.Message
            # don't respond with $_.Exception.Message to avoid leaking any unexpected information.
            ImmediateFailure "$($_.Exception.Response.StatusCode.value__) - Failed after 2 attempts to $itgUri." 
        }
        start-sleep (get-random -Minimum 1 -Maximum 10)
    }
}

# For organization specific data, only return records linked to the authorized client.
#if ($itgRequest.data.type -contains "organizations" -or 
#     $itgRequest.data[0].attributes.'organization-id') {

#     $itgRequest.data = $itgRequest.data | Where-Object {
#         ($DISABLE_ORGLIST_CSV) -or
#         ($_.type -eq "organizations" -and $_.id -in $allowedOrgs.ITGlueOrgID) -or
#         ($_.attributes.'organization-id' -in $allowedOrgs.ITGlueOrgID)
#     }
# }

# Strip out any paramaters from the body which haven't been explicitly whitelisted.
if ($endpoints[$endpointKey].returnbody) {
    $itgReturnBody = Build-Body $endpoints[$endpointKey].returnbody $itgRequest
    if ($itgRequest.meta) {
        $itgReturnBody | Add-Member -NotePropertyName 'meta' -NotePropertyValue $null
        $itgReturnBody.meta = $itgRequest.meta
    }
    if ($itgRequest.links) {
        $itgReturnBody | Add-Member -NotePropertyName 'links' -NotePropertyValue $null
        $itgReturnBody.links = $itgRequest.links
    }
} else {
    $itgReturnBody = @{}
}

# Log response body if the debug level is trace. 
Write-Verbose ("Response body: {0}" -f ($itgReturnBody | Convertto-Json -Depth 6))

# Return the final object.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    headers    = @{'content-type' = 'application\json' }
    StatusCode = [System.Net.HttpStatusCode]::OK
    Body       = ($itgReturnBody | ConvertTo-Json -Depth 6)
})