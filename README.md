# AWS Windows User Data

This is a userdata script for a fairly particular use case: mapping
volumes to drive letters based on EC2 tags.

## Rationale

It's an extension of the EC2Config option to always mount a drive with a
particular label to a particular drive letter.

The problem with that is that the drive has to have a particular label.
Now, generally that's not a big deal.  You're setting up something like
that because you are passing drives on EC2 EBS volumes around between
multiple instances.

However, it might be nice, especially if the first stage of your
processing pipeline is to generate the data on the volumes in the first
place, to be able to start with an empty block device and have it
initialized and mounted to the correct place.  Hence this project.

The script-running functionality is in place so you can just create an
AMI with a C:\Scripts\Startup directory and ignore the Windows
Scheduler, which if you want to spend as little time as possible logged
into the instance, is handy.

## How to use

### Drive Mapping

* Create an instance with an attached role.  The role needs to be able
  to examine the instance, examine the attached EBS volumes, and read
  the tags on those volumes.  The existing Amazon policies
  ReadOnlyAccess or AmazonEC2ReadOnlyAccess are certainly broad enough,
  but could be tightened if you want to.  This is in Step 3: Configure
  Instance Details, if you're launching a new instance from the console.

* Put the Powershell script between `<powershell>` `</powershell>` tags,
  and put that in the User Data field of a Windows instance you're
  launching.  It's in Step 3: Configure Instance Details, down at the
  bottom inside Advanced Details, if you're using the console.

* For all the EBS volumes you want to automount, add a DriveLetter tag
  and a DriveLabel tag.  The DriveLetter should be a Windows drive
  letter, and as such, should be in the range D: to Z: -- it should end
  in a colon, and you don't get to do this to the boot drive or either
  of the floppy drives.  The Drive Label should follow Windows naming
  conventions for disk volumes; since an empty EBS volume will be
  partitioned with a single partition taking up the whole volume, and
  will be formatted with NTFS, this only means, keep it under 32
  characters.

* Start (or restart) the instance with the tagged EBS volumes attached.
  When the instance is up and you connect to it, you will see that it
  has drives, labelled with the DriveLabel tag, mounted at the letters
  specified with the DriveLetter tag.

### Startup Scripts

Create a directory called C:\Scripts\Startup.  Put scripts you want to
run at instance start time in there.  They will be run in lexical-sort
order, and must be Powershell scripts with a .ps1 extension.  There is
no error handling on these.

## Limitations

This only works with Amazon EC2.  The drive mapper only works with EBS
volumes.  The startup script execution is remarkably simple-minded.
