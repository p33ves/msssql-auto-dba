# PatchSQL

AutoPatch.ps1 contains code to Patch any set of specific SQL Versions to their appropriate patch levels provided by their config file.

BuildPatchObject.ps1 conatins code that creates a JSON object that contains information regarding the patch type and processes that need to be performed during the SQL Server patching processes.

ChangeConfig.ps1 can be used to update the new target versions that need to applied, and the path of the appropriate .exe file
