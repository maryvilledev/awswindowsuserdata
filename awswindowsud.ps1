# Used for AWS Windows AMI Userdata.
#
# Two main functions:
#  1. Remap drives based on the EC2 tags "DriveLetter" and "DriveLabel".  These
#     tags are expected on EBS volumes, and "DriveLetter" should end in ":".
#     For this to work, the instance must be launched with the "readonlyEC2"
#     role, so it can get the volume tags.
#  2. Run any scripts (in lexical sort order) that are in C:\Scripts\Startup
#     and have a ".ps1" extension.  That way your custom AMI, based on an 
#     Amazon Windows AMI, can define scripts in that directory and run them 
#     on boot.
#
#  This script will enable policy to allow the AWS Powershell tools to run,
#   and will install those tools as well.  It also sets disk policy to bring
#   all disks online by default, and sets the EC2Config setting such that 
#   userdata (i.e. this script) is run on every boot.

function install-AWSpackage {
    # Try the import
    $junk=(Import-Module AWSPowerShell)
    $m=(Get-Module -Name "AWSPowerShell")
    if ($m) {
        # Already installed.
        return
    }
    $awsurl="http://sdk-for-net.amazonwebservices.com/latest/AWSToolsAndSDKForNet.msi"
    $outdir="C:\Downloads"
    $isoutdir=Test-Path -path $outdir
    if (! $isoutdir) {
        New-Item -type directory $outdir
    }
    $output=$outdir + "\awssdk.msi"
    $wc=New-Object System.Net.WebClient
    $wc.DownloadFile($awsurl,$output)
    msiexec /qn /i $output
    Import-Module AWSPowerShell
    # Clean up
    Remove-Item $output 
    if (! $isoutdir) {
        Remove-Item -recurse $outdir
    }
}

function Enable-UserData {
    # This path is always constant for an Amazon Windows AMI
    $path="C:\Program Files\Amazon\Ec2ConfigService\Settings\config.xml"
    $xml=[xml](Get-Content $path) 
    $node=($xml.Ec2ConfigurationSettings.Plugins.Plugin | where {$_.Name -eq "Ec2HandleUserData"})
    if ($node.State -ne "Enabled") {
        $node.State="Enabled"
        $xml.Save($path)
    }    
}

function Remap-Drives {
    Set-StorageSetting -NewDiskPolicy OnlineAll
    $diskset=Get-NonBootDisks
    ForceReadWrite-Disks($diskset)
    Reattach-Disks($diskset)
    # Get mapping
    $map=RelabelAndMapDrives
    $tempdrive=Get-FreeDriveLetter
    Fix-DriveLetters $tempdrive $map
}

function Get-NonBootDisks {
    # Rescan disks
    Update-HostStorageCache
    get-Disk | ?{$_.Number -gt 0}  
}

function ForceReadWrite-Disks($diskset) {
    # All non-boot disks become read-write 
    echo $diskset | set-Disk -isReadOnly $false
}

function Reattach-Disks($diskset) {    
    # Detach, then reattach, disks in presented diskset
    foreach ($b in ($true,$false)) {echo $diskset | set-Disk -isOffline $b }
    Update-HostStorageCache
}

function RelabelAndMapDrives {
    # EC2 read-only role is "readonlyEC2"
    $role="readonlyEC2"
    # Get the AZ, which lets us derive the region
    $az=Get-EC2Metadata("/placement/availability-zone")
    $region=$az.Substring(0,$az.Length-1)
    # Get session creds (need to launch instance with readonlyEC2 role)
    $creds=(Get-EC2Metadata("/iam/security-credentials/$role")| ConvertFrom-Json)
    $id=Get-EC2Metadata("/instance-id")
    $aki=($creds.AccessKeyId)
    $sak=($creds.SecretAccessKey)
    $tok=($creds.Token)
    $inst=(get-ec2instance -region $region -accesskey $aki -secretkey $sak -sessiontoken $tok -instanceid $id).Instances
    $bdm=$inst.BlockDeviceMappings | ?{$_.DeviceName -ne "/dev/sda1"}
    $map=@{}
    # Get list of logical disks to match EC2 devices
    # Relying on Windows disks and EC2 devices to be in reversed order.  Not at all sure this is reliable
    $ldisks = Get-LogicalDisks
    $lindex=$bdm.Length # Initialize
    $refresh=0
    foreach ($b in $bdm) {  
        # Count up for EBS block devices.
        $lindex-- # Start at ($bdm.Length - 1) and count down for Win32_LogicalDisks
        $volid=$b.Ebs.VolumeId
        $driveletter=(get-ec2Tag -region $region -accesskey $aki -secretkey $sak -sessiontoken $tok -Filter @{ Name="resource-id";Values="$volid"},@{ Name="key";Values="DriveLetter"}).Value
        $drivelabel=(get-ec2Tag -region $region -accesskey $aki -secretkey $sak -sessiontoken $tok -Filter @{ Name="resource-id";Values="$volid"},@{ Name="key";Values="DriveLabel"}).Value
        if ( $ldisks -and $drivelabel) {
            $ld=$ldisks[$lindex]
            $ntfslbl=$ld.VolumeName
            $dlett=$ld.DeviceID
            if ($ntfslbl -ne $drivelabel) {
                # Relabel disk to match EC2 Tag for drive label
                $disk=Get-WMIObject win32_volume | Where {$_.DriveLetter -eq $dlett}
                if ($disk) {
                    $disk.Label=$drivelabel
                    $junk=$disk.Put()
                    $refresh=1
                }
            }
        }
        if (($driveletter) -and ($drivelabel)) {
            # Make sure it ends in a colon.
            if ($driveletter.Substring(($driveletter.Length) - 1) -ne ':') {
                $driveletter=$driveletter+':'
            }
            $map.Add($drivelabel,$driveletter)
        }
    }
    if ($refresh) {
        Update-HostStorageCache
    }
    # Return the label-to-letter map
    $map
}

function Get-EC2Metadata($item) {
    $md="http://169.254.169.254/latest/meta-data"
    if ($item.Substring(0,1) -ne '/') {
        # Prepend a slash if it doesn't start with one.
        $item = '/' + $item
    }   
    $uri=$md + $item
    (Invoke-WebRequest -uri $uri -UseBasicParsing).Content
}

function Get-LogicalDisks {
    # Skip the first disk, and only get the first partition on any disk.
    #  This works fine for auto-formatted EBS disks, since a new device is given a single partition
    #  and then formatted with NTFS.
    get-wmiobject win32_diskpartition | where {($_.diskindex -ne 0) -and ($_.index -eq 0) } | %{$_.getrelated('Win32_LogicalDisk')}
}

function Get-FreeDriveLetter {
    # http://www.powershellmagazine.com/2012/01/12/find-an-unused-drive-letter/
    for($j=67;gdr($d=[char]++$j)2>0){}$d + ':'
}

function Fix-DriveLetters($tempdrive,$map) {
    # For each label/letter mapping, if the drive isn't already mapped there:
    #  If there is some drive mapped there, move that drive to the tempdrive (which is the first free drive letter).
    #  Then move the labelled drive to the right letter.
    #  If you had to move a drive out of the way, move it to the labelled drive's original letter.
    foreach($h in $map.GetEnumerator()) {
        $driveletter=$h.Value
        $label=$h.Name        
        $lqry="Label = '$label'"
        $drive=Get-WMIObject win32_volume -filter "$lqry"
        if ($drive) {
            $dl=$drive.DriveLetter
            if ( $dl -ne $driveletter) {
                $dlqry="DriveLetter = '$driveletter'"
                $movedrive=Get-WMIObject win32_volume -filter "$dlqry"
                if ($movedrive) {
                    if (! $tempdrive) {
                        Throw 'Could not get free drive letter; cannot swap disks.'
                        return # Not reached
                    }
                    $movedrive.DriveLetter=$tempdrive
                    $junk=$movedrive.Put()
                }
                $drive.DriveLetter=$driveletter
                $junk=$drive.Put()
                if ($movedrive) {
                    $movedrive.DriveLetter=$dl
                    $junk=$movedrive.Put()
                }
            }
        }
    }   
}

function Run-StartupScripts {
    $startscriptpath="C:\Scripts\Startup"
    Run-Scripts($startscriptpath)
}

function Run-Scripts($path) {
    if ( ! ($path -and ( Test-Path $path ) ) ) {
        # No script directory
        return
    }
    $scripts=(Get-ChildItem -Path $path | Where { $_.Extension -eq ".ps1" } | Sort).Name
    foreach ($s in $scripts) {
        $spath=$path + '\' + $s
        Invoke-Expression $spath
    }
}

function main {
    # It's actually run as unrestricted anyway
    Set-ExecutionPolicy RemoteSigned
    Install-AWSPackage
    Enable-UserData
    Remap-Drives
    Run-StartupScripts
}

main
