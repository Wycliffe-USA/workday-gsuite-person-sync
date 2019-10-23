# Workday to gSuite Person Sync
# V 1.1

Synchronizes users from Workday to gSuite.  Responsible for new account creation, account information updates, and account deactivations.

## Project Information

This project is designed to run in a Linux docker container.  It utilizes the powershell language and powershell (core) command line interpreter.

An example of how to run the script is: (see prerequisites first)
```
docker run -it -e workdayRptUsr='ISU_gSuite' -e workdayRptPwd='{Insert_Password}' -e workdayRptUri='https://services1.myworkday.com/ccx/service/customreport2/wycliffe/DAVE_GUELL/CRX_-_Workday-gSuite-Sync?format=json' -v c:\path\to\config:/config dockerhub.wycliffe.org:5000/workday-gsuite-person-sync:latest -Confirm
```
Other options can be overridden by passing them on the command prompt.

## Prerequisites to running:
* Config directory
** A `/config` directory is required which holds either the `Configuration.psd1` or `Configuration.json` file from the PS-GSuite tool. This config dir can be located in the same directory as this repository.  It will be ignored by git.  To obtain these files..
*** Obtain the `/config` directory from an existing source, such as the server that runs this process.  OR..
*** Configure PSGSuite from scratch
**** Start the container as specified above, except remove `-Confirm` and add `pwsh` to the end of the command to start a powershell.
**** Follow the instructions at this page to set up a google developer project, permissions, and create a PSGSuite configuration file. https://github.com/scrthq/PSGSuite/wiki/Initial-Setup
**** Test the configuration with `get-gsuser -Filter *`
**** Once you have a working configuration, copy the configuration file generated from the PSGSuite to the `/config` directory.  If this is mounted to a folder on your computer you can continue to use this config directory.
***** `cp '/root/.config/powershell/SCRT HQ/PSGSuite/Configuration.psd1' /config/`

## Building and storing the docker image:
The container runs from an image that is build and stored in the local docker hub repository.
### Build
```
cd [this directory]
docker build -t dockerhub.wycliffe.org:5000/workday-gsuite-person-sync:latest .
```

### Push the image to the repository
```
docker push dockerhub.wycliffe.org:5000/workday-gsuite-person-sync:latest
```

### Working with special or un-managed accounts.
There are certain accounts that do not fall under the normal management mechanism.  In other words, certain people may not show up in the Workday report that feeds this automation script.  However, they still need a gSuite account.  Additionally, there may be a need to place them into a certain OU for rights assignment.  Consequently, we cannot rely on a single OU to maintain a list of these types of accounts.
For the reason of dealing with certain accounts that should not be managed by the Sync, a custom attribute was added to those accounts.  Custom attributes can be managed through the Google Admin interface, as described here (https://support.google.com/a/answer/6208725?hl=en) and you can set a user's custom attributes on their account in the web interface just like any other attribute.  A custom attribute was added called `workday_managed` under the category `wusa_custom_attributes`
You can see this attribute by using the PSGSuite module and typing in `get-gsuser -User user_name` and seeing if the user has any value in the `CustomSchemas` field.  To see the CustomSchemas detail type `(get-gsuser -User user_name).CustomSchemas`.
To make a user account immune to action by the workday-gSuite sync (or un-managed), find the user in Google Admin.  Under user information, find `wusa_custom_attributes` and `workday_managed`.  Change the value of `workday_managed` to `No`.
To find a list of all accounts with custom schemas
```
$gSuiteUsers = Get-GSUser -Filter *
ForEach ($gSuiteUser in $gSuiteUsers){
  if ($gSuiteUser.CustomSchemas){
    $gSuiteUser
    $gSuiteUser.CustomSchemas
  }
}
```