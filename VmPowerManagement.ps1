workflow VMPowerAssesment
{
    Function Set-MRVVMPowerState
    {
        param(
            [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]
            [string]
            $vmId,

            [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]
            [ValidateSet("Started", "StoppedDeallocated" )]
            [string]
            $DesiredState,

            [Parameter (Mandatory = $false)]
            [switch]
            $Simulate
        )
        $EventAppName = "PowerShellAutomation"
        # Get VM with current status
        Write-Verbose "Getting VM resource with ID $vmId"
        $VirtualMachine = Get-AzureRmResource -ResourceId $vmId
        Write-Verbose "Getting VM with Name [$($VirtualMachine.Name)] from the RG [$($VirtualMachine.ResourceGroupName)]"
        try
        {
            $VM = Get-AzureRmVM  -ResourceGroupName $VirtualMachine.ResourceGroupName -Name $VirtualMachine.Name -Status
        }
        catch
        {
            #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 8030 -EntryType Error -Message "Failed to get VM with Name [$($VirtualMachine.Name)] from the RG [$($VirtualMachine.ResourceGroupName)]" -Category 1
            #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 8031 -EntryType Error -Message $Error -Category 1
            return
        }

        #return
        $currentStatus = $VM.Statuses | where Code -like "PowerState*"
        $currentStatus = $currentStatus.Code -replace "PowerState/", ""

        # If should be started and isn't, start VM
        if ($DesiredState -eq "Started" -and $currentStatus -notmatch "running")
        {
            if ($Simulate)
            {
                Write-Verbose "[$($VirtualMachine.Name)]: SIMULATION -- Would have started VM. (No action taken)"
            }
            else
            {
                Write-Verbose "[$($VirtualMachine.Name)]: Starting VM"
                try
                {
                    $result = $VM | Start-AzureRmVM
                }
                catch
                {
                    #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 8040 -EntryType Error -Message "[$($VirtualMachine.Name)]: VM Failed to start" -Category 1
                    #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 8041 -EntryType Error -Message $Error -Category 1
                    return
                }
            }
        }
        # If should be stopped and isn't, stop VM
        elseif ($DesiredState -eq "StoppedDeallocated" -and $currentStatus -ne "deallocated")
        {
            if ($Simulate)
            {
                Write-Verbose "[$($VirtualMachine.Name)]: SIMULATION -- Would have stopped VM. (No action taken)"
            }
            else
            {
                Write-Verbose "[$($VirtualMachine.Name)]: Stopping VM due to DesiredState is $DesiredState and currentStatus is $currentStatus and ifAlwaysON is $ifAlwaysON)"
                try
                {
                    $result = $VM | Stop-AzureRmVM -Force
                }
                catch
                {
                    #Write-EventLog -LogName "Application" -Source $EventAppName -EventID 8050 -EntryType Error -Message "[$($VirtualMachine.Name)]: VM Failed to Stop" -Category 1
                    #Write-EventLog -LogName "Application" -Source $EventAppName -EventID 8051 -EntryType Error -Message $Error -Category 1
                    return
                }
            }
        }

        # Otherwise, current power state is correct
        else
        {
            Write-Verbose "[$($VirtualMachine.Name)]: Current power state [$currentStatus] is correct."
        }
        [string]$ResultText = $result
    
        Write-Verbose  "Assesment of VM [$($VirtualMachine.Name)] Finished Successully."
        Write-Verbose  $ResultText
    }
    Function Start-MRVVMPowerAssesment
    {
        param(
            [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]
            [string]
            $SubscriptionName = $(throw "Please Provide the Subscription name!"),
            [Parameter (Mandatory = $false)]
            [switch]
            $Simulate
        )
        $EventAppName = "PowerShellAutomation"
        $UTCTime = (Get-Date).ToUniversalTime()
        $oToTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")
        $currentTime = [System.TimeZoneInfo]::ConvertTime($UTCTime, $oToTimeZone)
        $Message = ""
        $VMStates = @()
        #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 8001 -EntrySubscriptionName Information -Message "Runbook started at [$currentTime] for Subscription [$SubscriptionName]" -Category 1
        Write-Verbose "Runbook started at [$currentTime] for Subscription [$SubscriptionName]"
        if ($Simulate)
        {
            Write-Verbose "*** Running in SIMULATE mode. No power actions will be taken. ***"
            #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 80010 -EntrySubscriptionName Warning -Message "*** Running in SIMULATE mode. No power actions will be taken. ***" -Category 1
        }
        else
        {
            Write-Verbose "*** Running in LIVE mode. Schedules will be enforced. ***"
        }
        Write-Verbose "Current time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))] will be checked against schedules"
        Write-Verbose "Logging in to $SubscriptionName"
        Select-MRVSubscription -SubscriptionName $SubscriptionName

        $Days = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
        Write-Verbose "Getting VM"
        [string]$time = Get-Date -Format 'yyyy-MM-dd-HH-mm'
        $DayToday = (get-date).DayOfWeek
        $WeekOfMonth = [math]::Floor(((Get-Date).Day - 1) / 7 + 1)
        $Patching_Schedule = "23:00->03:00"
        $PatchingTagName = "Patching_Schedule"
        Write-Verbose "Today is $DayToday and week number [$WeekOfMonth]"

        # Get a list of all virtual machines in subscription
        $VMList = Get-AzureRmVM
        Write-Verbose "Processing VMs. We have $($VMList.Count) to proceed"
        Write-Verbose "Processing [$($VMList.Count)] virtual machines found in subscription"
        ForEach ($VM in $VMList)
        {
            Write-Verbose "Processing VM [$($VM.name)]"
            $Schedule = $null
            $VMtags = $null
            $VMtags = $VM.Tags
            if ($VMtags -eq $null)
            {
                # No direct or inherited tag. Skip this VM.
                Write-Verbose "[$($VM.Name)]: Does not have any tags for start / stop management. Skipping this VM."
                continue
            }
            $ifAlwaysOn = $false
            $ifAlwaysOff = $false
            If (($VMtags.GetEnumerator() | Where-Object {$_.Key -like "AlwaysON"}).value -like "*true")
            {
                $ifAlwaysOn = $true
                Write-Verbose "[$($VM.Name)]: Has AlwaysOn set to TRUE ($ifAlwaysOn)"
            }
            else
            {
                #$ifAlwaysOn = $false # Already set above
                Write-Verbose "[$($VM.Name)]: Has AlwaysOn set to False ($ifAlwaysOn)"
            }
            If (($VMtags.GetEnumerator() | Where-Object {$_.Key -like "AlwaysOFF"}).value -like "*true")
            {
                $ifAlwaysOff = $true
                Write-Verbose "[$($VM.Name)]: Has AlwaysOFF set to TRUE ($ifAlwaysOff)"
            }
            else
            {
                #$ifAlwaysOff = $false # Already set above
                Write-Verbose "[$($VM.Name)]: Has AlwaysOFF set to False ($ifAlwaysOff)"
            }
            #Write-Verbose "After Always Tags"
            #$VMtags.GetEnumerator()
            If (($ifAlwaysOn) -and ($ifAlwaysOff))
            {
                Write-Verbose "[$($VM.Name)]: Has AlwaysOn and AlwaysOff both set to TRUE. This doesn't make sense. Skipping...."
                continue
            }

            If ((-not $ifAlwaysOn) -and (-not $ifAlwaysOff))
            {
                try
                {
                    $Schedule = ($VMtags.GetEnumerator() | Where-Object {$_.Key -like "Schedule_$DayToday"}).Value
                }
                catch
                {
                    # No direct or inherited tag. Skip this VM.
                    Write-Verbose "[$($VM.Name)]: Not tagged for the $DayToday. Skipping this VM."
                    continue
                }
                if ($Schedule -eq $null)
                {
                    # No direct or inherited tag. Skip this VM.
                    Write-Verbose "[$($VM.Name)]: Not tagged for the $DayToday. Skipping this VM."
                    continue
                }
                # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
                $timeRangeList = @($schedule -split "," | ForEach-Object {$_.Trim()})
                Write-Verbose "Check each range against the current time to see if any schedule is matched"
                $IsScheduleMatched = $false
                $MatchedSchedule = $null
                foreach ($entry in $timeRangeList)
                {
                    Write-Verbose "Processing Entry [$entry]"
                    if (Test-MRVPowerScheduleEntry -TimeRange $entry)
                    {
                        Write-Verbose "Based on Time Entry [$entry] VM Schedule is matched."
                        $IsScheduleMatched = $true
                        $MatchedSchedule = $entry
                        break
                    }
                }
            }
            elseif ($ifAlwaysOn)
            {
                Write-Verbose "Based on AlwaysOn [$ifAlwaysOn] VM Schedule is matched."
                $IsScheduleMatched = $true
                $MatchedSchedule = 'AlwaysOn'

            }
            elseif ($ifAlwaysOff)
            {
                Write-Verbose "Based on AlwaysOff [$ifAlwaysOff] VM Schedule do not match."
                $IsScheduleMatched = $false
            }
            # After all checks - we are checking if the VM need to be UP for the maintenance. Even if it is alwaysOFF - it need to be kept up to date.
            Write-Verbose "Checking if the VM need to be UP for the maintenance. Even if it is alwaysOFF - it need to be kept up to date."
            if ($VMtags.ContainsKey($PatchingTagName))
            {
                Write-Verbose "Patching Tag found. Checking if it is time for patching.."
                $PatchingGroup = ($VMtags.GetEnumerator() | Where-Object {$_.Key -like $PatchingTagName}).Value
                Write-Verbose "We have got Patching Group [$PatchingGroup]. Is it time for patching?"
                $PatchingWeekNumber = $PatchingGroup.Substring(1, 1)
                $PatchingDay = $PatchingGroup.Substring(3, 3)
                if (($PatchingDay -eq $DayToday.ToString().substring(0, 3).ToUpper()) -or ($PatchingDay -eq (get-date).AddDays(-1).DayOfWeek.ToString().substring(0, 3).ToUpper()))
                {
                    Write-Verbose "It looks like currently Patching or After Patching Day. Checking the Time"
                    if ((Test-MRVPowerScheduleEntry -TimeRange $Patching_Schedule -Patching))
                    {
                        Write-Verbose "It looks like currently patching time, so we need to ensure that VM is up."
                        $IsScheduleMatched = $true
                        $MatchedSchedule = $Patching_Schedule
                    }
                }
                else
                {
                    Write-Verbose "Not a Patching Day..."
                }
            }
            else
            {
                Write-Verbose "Patching Group Not Specified"
            }
            # Enforce desired state for group resources based on result.
            if ($IsScheduleMatched)
            {
                # Schedule is matched. Start the VM if it is not running.
                Write-Verbose "[$($VM.Name)]: Current time [$currentTime] falls within VM running range [$MatchedSchedule]"
                $DesiredState = "Started"
            }
            else
            {
                # Schedule not matched. Shut down VM if not stopped.
                Write-Verbose "[$($VM.Name)]: Current time falls within scheduled shutdown ranges."
                $DesiredState = "StoppedDeallocated"
            }
            $VMStates += @{VM = $VM; DesiredState = $DesiredState}
        }


        Write-Verbose "We have [$($VMStates.Count)] VMstates to process"
        foreach -parallel ($VMState in $VMStates)
        {
            $VM = $VMState.VM
            $DesiredState = $VMState.DesiredState
            Write-Verbose "VM ID [$($VM.Id)]"
            Set-MRVVMPowerState -vmId $VM.Id -DesiredState $DesiredState -Simulate:$Simulate -verbose
        }
        $Message = "Runbook started at [$currentTime] for Subscription [$SubscriptionName] finished. (Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $UTCTime))))"
        Write-Verbose $Message
        #Write-EventLog -LogName "Application" -Source "$EventAppName" -EventID 8002 -EntrySubscriptionName Information -Message $Message -Category 1
    }




}